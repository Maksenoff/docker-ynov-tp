# TP07 - Observabilité

Fichiers :

- [compose.observability.yml](compose.observability.yml) : prometheus, alertmanager + webhook (B2), cadvisor, loki, promtail, grafana ;
- [prometheus/prometheus.yml](prometheus/prometheus.yml), [prometheus/alerts.yml](prometheus/alerts.yml) ;
- [promtail/config.yml](promtail/config.yml), [loki/config.yml](loki/config.yml) ;
- [grafana/provisioning/](grafana/provisioning/) (datasources + provider), [grafana/dashboards/shop.json](grafana/dashboards/shop.json) ;
- [load.sh](load.sh).

```bash
cd ../tp04-compose-entreprise && make up && cd -
docker compose -f compose.observability.yml up -d
./load.sh 1000
# http://localhost:9090/targets   http://localhost:3001 (admin/admin)   http://localhost:9093
```

## 1. Logs côté Docker

```
$ docker logs --since 5m --timestamps shop-api-1 | jq
```

Avec `--timestamps` docker ajoute la date devant chaque ligne, donc `jq` ne parse plus. Il faut l'enlever :
`docker logs --since 5m shop-api-1 | jq` ou `docker logs --since 5m --timestamps shop-api-1 | cut -d' ' -f2- | jq`.

```
{
  "level": 30,
  "time": 1761733512345,
  "pid": 1,
  "hostname": "3c1e0f2b9a7d",
  "req": { "id": 12, "method": "GET", "url": "/products", ... },
  "res": { "statusCode": 200, ... },
  "responseTime": 3,
  "msg": "request completed"
}

$ docker inspect shop-api-1 --format '{{.HostConfig.LogConfig}}'
{json-file map[max-file:3 max-size:10m]}

$ sudo ls -la /var/lib/docker/containers/$(docker inspect shop-api-1 -f '{{.Id}}')/
-rw-r----- 1 root root 1843211 Oct 29 14:02 3c1e0f2b9a7d...-json.log
-rw-r----- 1 root root 10485760 Oct 29 13:40 3c1e0f2b9a7d...-json.log.1
...

$ docker run --rm --log-driver none alpine echo "pas loggé"
pas loggé
$ docker logs <id>
Error response from daemon: configured logging driver does not support reading
```

(Sur Docker Desktop, `/var/lib/docker` est dans la VM : `docker run --rm -it --privileged --pid=host alpine nsenter -t 1 -m -u -n -i sh`.)

**Sans `max-size` pendant 6 mois** : le driver `json-file` n'a pas de rotation par défaut, le fichier `-json.log`
grossit sans limite (un log par requête HTTP = plusieurs Go par mois). Le disque `/var/lib/docker` se remplit, et
quand il est plein : plus d'écriture possible pour **tous** les conteneurs (bases de données comprises), docker
lui-même plante, impossible de pull. Et `docker logs` devient très lent.

**Pourquoi stdout/stderr et pas un fichier** :

- le runtime capture stdout/stderr, c'est donc lui (driver de log) qui gère rotation, envoi, format. L'appli n'a rien
  à configurer et on peut changer de destination sans toucher l'image ;
- un fichier dans le conteneur va dans la couche writable (perdu au `rm`, grossit sans rotation, ralentit l'overlay)
  ou dans un volume qu'il faudrait collecter à part ;
- `docker logs`, `docker compose logs`, Promtail (via la socket), Kubernetes : tout l'écosystème lit stdout/stderr ;
- principe des 12-factor apps : les logs sont un flux d'événements.

**Drivers** :

| Driver | Principe | `docker logs` |
|---|---|---|
| `json-file` | défaut, un fichier JSON par conteneur sur l'hôte | oui |
| `local` | format binaire compressé, rotation activée par défaut (20 Mo x 5), plus performant | oui |
| `journald` | envoie au journal systemd (`journalctl CONTAINER_NAME=...`) | oui |
| `fluentd` | envoie en réseau à un fluentd/fluent-bit | oui (via le "dual logging" depuis docker 20.10) |
| `awslogs` | envoie à CloudWatch Logs | idem |

**`mode: non-blocking` + `max-buffer-size`** : par défaut (`blocking`) l'écriture sur stdout de l'appli attend que le
driver ait accepté la ligne. Si le driver est lent (fluentd injoignable, disque lent), **l'appli est bloquée** (les
requêtes HTTP gèlent). En `non-blocking`, les logs passent par un buffer en mémoire (`max-buffer-size`, 1 Mo par
défaut) : l'appli n'est jamais bloquée, mais si le buffer est plein **les logs sont perdus**. Compromis : disponibilité
de l'appli vs exhaustivité des logs.

## 2. Métriques côté Docker

```
$ docker stats --no-stream
CONTAINER ID   NAME             CPU %   MEM USAGE / LIMIT     MEM %   NET I/O          BLOCK I/O   PIDS
3c1e0f2b9a7d   shop-api-1       0.12%   48.2MiB / 256MiB      18.8%   1.2MB / 2.3MB    0B / 0B     11
...
$ docker system df -v
$ docker events --filter type=container --since 10m
```

OOM : on limite l'api à 64 Mo à chaud et on charge :

```bash
docker update --memory 64m --memory-swap 64m shop-api-1
PARALLEL=50 ./load.sh 20000
docker events --filter type=container --filter container=shop-api-1
```

```
2026-10-29T14:20:11 container oom 3c1e0f2b9a7d (image=..., name=shop-api-1)
2026-10-29T14:20:11 container die 3c1e0f2b9a7d (exitCode=137, ...)
2026-10-29T14:20:12 container start 3c1e0f2b9a7d (...)

$ docker inspect shop-api-1 --format '{{.State.OOMKilled}} {{.RestartCount}}'
true 1
```

Le noyau tue le process quand le cgroup dépasse la limite (exit 137 = 128 + SIGKILL), docker le redémarre grâce à
`restart: unless-stopped`. Dans Grafana on voit la mémoire monter jusqu'à la limite puis retomber, et les alertes
`ContainerOOMKilled` / `ContainerRestarting` passent en `firing`.
Pour node il vaudrait mieux aussi régler `NODE_OPTIONS=--max-old-space-size=...` en dessous de la limite, sinon V8 ne
voit pas la limite du cgroup et ne lance pas le GC assez tôt.

## 3. Stack d'observabilité

### Réseaux

La stack est un projet compose séparé (`observability`) : elle ne connaît pas les services du TP04 par défaut. Elle
rejoint le réseau `shop_back` déclaré `external` (créé par la stack shop, donc la stack shop doit tourner avant).
Le reste (cadvisor, loki, grafana...) est sur son propre réseau `obs`.

Je n'ai mis que `shop_back` et pas `shop_front` : l'api est sur les deux réseaux, si prometheus était aussi sur les
deux, la résolution DNS de `api` pourrait renvoyer les IP des deux réseaux et chaque replica serait scrapé deux fois.
`shop_back` suffit puisque api **et** worker y sont.

### Prometheus

- cadvisor en `static_configs` ;
- api et worker en `dns_sd_configs` (type A) : le DNS embarqué de docker renvoie **une IP par replica** pour le nom
  du service, Prometheus scrape donc chaque replica séparément (label `instance`), et suit le scale tout seul
  (`refresh_interval: 15s`).

```
$ curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.labels.instance) \(.health)"'
api 172.21.0.5:3000 up
api 172.21.0.6:3000 up
cadvisor cadvisor:8080 up
prometheus localhost:9090 up
worker 172.21.0.4:9100 up
```

**Pourquoi pas `docker_sd_configs`** :

```
$ docker exec observability-prometheus-1 id
uid=65534(nobody) gid=65534(nogroup)
```

L'image prometheus tourne en `nobody`. La socket docker (`/var/run/docker.sock`) appartient à `root:docker` en
`660` : nobody ne peut pas la lire. Il faudrait lancer prometheus en root ou l'ajouter au groupe docker (`group_add`),
ce qui revient à lui donner un accès root sur l'hôte (la socket docker = root). Pour un service exposé sur le réseau
c'est un gros risque. La découverte DNS n'a besoin d'aucun privilège.

### Loki + Promtail

Promtail, lui, a besoin de la socket (`docker_sd_configs`) pour découvrir les conteneurs et lire leurs logs. Il est
monté en `:ro` (ce qui ne protège pas grand chose sur une socket, mais bon) et n'est exposé sur aucun port.

- relabel : `service` et `project` depuis les labels `com.docker.compose.service` / `com.docker.compose.project`,
  `container` depuis le nom ;
- pipeline : `json` extrait `level`, mis en label (peu de valeurs différentes, donc pas de problème de cardinalité).

Requêtes dans Explore → Loki :

```
{service="api"} | json | level="50"         # erreurs pino (50 = error, 60 = fatal)
{service="worker"} |= "rejected"            # commandes rejetées (quantity > 100 dans load.sh)
```

### Grafana

Tout est provisionné par fichiers, aucun clic : datasources Prometheus et Loki avec un `uid` fixe (référencé dans
le dashboard), provider de dashboards qui lit `/etc/grafana/dashboards`. Le dashboard "Shop SAS - vue d'ensemble"
(dossier Shop SAS) contient : replicas up, worker up, taux de 5xx, p95, req/s par status et par replica, latences
p50/p95/p99, commandes traitées par status, CPU / mémoire / réseau par conteneur (cadvisor), logs en erreur,
commandes rejetées.

`allowUiUpdates: false` : on ne peut pas modifier le dashboard dans l'UI, toute modif passe par le JSON dans git.

### Alertes

| Alerte | Expression |
|---|---|
| ApiDown | `sum(up{job="api"}) == 0 or absent(up{job="api"})` (le `absent` couvre le cas où il n'y a plus aucune cible) |
| ApiHigh5xxRate | `rate(5xx) / rate(total) > 0.05` |
| ApiHighLatencyP95 | `histogram_quantile(0.95, ...) > 0.5` |
| ContainerRestarting | `changes(container_start_time_seconds[10m]) > 0` |
| ContainerOOMKilled | `increase(container_oom_events_total[5m]) > 0` |
| ContainerMemoryNearLimit | `working_set / limit > 0.9` en ignorant les conteneurs sans limite (limite = 0) |

Test : `docker compose -f ../tp04-compose-entreprise/compose.yml stop api` → `ApiDown` pending puis firing après 30 s,
visible sur `localhost:9090/alerts`, dans alertmanager (`localhost:9093`) et la notification arrive dans les logs du
webhook (`docker compose -f compose.observability.yml logs webhook`).

## 4. Corrélation

Méthode pour trouver une panne en moins de 5 min avec Grafana :

1. dashboard : quel indicateur a bougé et à quelle heure (5xx, latence, replicas up, mémoire, redémarrages) ;
2. Explore → Loki sur la même plage : `{project="shop", level=~"50|ERROR"}` pour lire le message d'erreur ;
3. vérifier avec docker.

| Panne injectée | Ce qu'on voit dans Grafana | Vérif docker |
|---|---|---|
| Redis arrêté | `/products` passe en MISS (logs), `/ready` 503 → taux de 5xx monte, commandes plus confirmées (panel worker à 0), logs `ECONNREFUSED redis:6379` / worker `erreur: Error ... connecting to redis:6379` | `docker compose ps redis` → exited |
| Mot de passe BDD changé | 5xx sur `/products` et `/orders`, logs api `password authentication failed for user "shop"` | `docker compose logs db` → `FATAL: password authentication failed` |
| Limite mémoire abaissée | mémoire de l'api collée à la limite, `ContainerOOMKilled` + `ContainerRestarting`, trous dans les req/s | `docker inspect --format '{{.State.OOMKilled}}'` → true |

## Bonus

### B1 - driver Loki / fluent-bit

```bash
docker plugin install grafana/loki-docker-driver:2.9.2 --alias loki --grant-all-permissions
```

```yaml
x-logging: &logging
  driver: loki
  options:
    loki-url: http://localhost:3100/loki/api/v1/push
    loki-batch-size: "400"
```

Avantages : pas de Promtail ni d'accès à la socket, les logs partent directement. Inconvénients : un plugin installé
sur chaque hôte (versions à gérer), si Loki est injoignable le driver peut **bloquer les conteneurs** ou perdre des
logs, il faut mettre le driver dans chaque compose, et le démarrage d'un conteneur échoue si le plugin est absent.
Promtail + socket est découplé : si Loki tombe, Promtail reprend à sa position (fichier `positions`).
Fluent-bit (driver `fluentd`) est plus généraliste (peut envoyer vers Loki, Elasticsearch, S3...) mais c'est un
composant de plus à faire tourner.

### B2 - Alertmanager

Intégré dans le compose : alertmanager + `mendhak/http-https-echo` sur le port 8085, config dans
[alertmanager/config.yml](alertmanager/config.yml). Les alertes sont groupées par `alertname`, `send_resolved: true`
envoie aussi la résolution.

```
$ docker compose -f compose.observability.yml logs webhook | tail
webhook-1  | {"path":"/alert","method":"POST","body":"{\"receiver\":\"webhook\",\"status\":\"firing\",\"alerts\":[{\"labels\":{\"alertname\":\"ApiDown\",...
```

### B3 - traces OpenTelemetry sans changer le code

On ajoute Jaeger (`jaegertracing/all-in-one:1.61`, OTLP sur 4318) et on installe l'auto-instrumentation dans une
image dérivée (pas le code applicatif) :

```dockerfile
FROM registry.local:5000/shopapi:1.4.2
USER root
RUN npm install --no-save @opentelemetry/auto-instrumentations-node@0.50.0 @opentelemetry/api@1.9.0
USER node
```

```yaml
  api:
    environment:
      NODE_OPTIONS: --require @opentelemetry/auto-instrumentations-node/register
      OTEL_SERVICE_NAME: shopapi
      OTEL_TRACES_EXPORTER: otlp
      OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4318
      OTEL_NODE_RESOURCE_DETECTORS: env,host,container
```

Express, pg et ioredis sont instrumentés automatiquement : on voit dans Jaeger la requête HTTP avec en dessous le
`GET products` redis et le `SELECT` postgres, avec leurs durées.

### B4 - alerte minimale sans Prometheus

```bash
#!/usr/bin/env bash
# alerte si un conteneur shop depasse 90% de memoire ou n'est pas healthy
while true; do
  docker stats --no-stream --format '{{.Name}} {{.MemPerc}}' | grep '^shop-' | tr -d '%' |
    awk '$2 > 90 { print "ALERTE memoire " $1 " " $2 "%" }'
  docker compose -f ../tp04-compose-entreprise/compose.yml ps --format '{{.Name}} {{.Health}}' |
    awk '$2 != "healthy" { print "ALERTE sante " $1 " " $2 }'
  sleep 30
done
```

`docker compose top` donne les process de chaque conteneur (utile pour voir un process zombie ou un fork en trop).

## Captures

Les captures du dashboard sous charge et des alertes en `firing` sont dans [captures/](captures/).
