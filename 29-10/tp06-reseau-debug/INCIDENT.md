# Rapport d'incident - préprod Shop SAS

**Heure de début** : 09h12 · **Heure de résolution** : 10h31 · **Impact** : préprod indisponible (front 8081 KO)

Fichiers corrigés : [compose.yml](compose.yml), [nginx/default.conf](nginx/default.conf).

## Chronologie du diagnostic

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 09h14 | `curl localhost:8081/products` → `Connection refused` | `curl -v localhost:8081/products` | le front ne tourne pas | confirmé |
| 09h16 | `docker compose up -d` plante avant même de démarrer | `docker compose config` → `can't set container_name and api as container name must be unique` | `container_name` + `replicas: 2` incompatibles (un nom de conteneur est unique) | confirmé, `container_name` retiré (A1) |
| 09h18 | `build` échoue : `unable to prepare context: path "../../tp04-compose-entreprise/solution/apps/shopapi" not found` | `docker compose build api` | chemin du contexte faux après réorganisation du repo | confirmé, chemin corrigé (A2) + même chose pour `init.sql` (A3) |
| 09h22 | front en `Exited (1)` | `docker compose logs front` → `error mounting "./nginx" to rootfs at "/etc/nginx/conf.d/default.conf": ... not a directory` | on monte un **dossier** sur un **fichier** | confirmé, bind mount sur `./nginx/default.conf` (A4) |
| 09h25 | front démarré mais `curl localhost:8081` → toujours refusé | `docker port incident-front-1` vide, `docker network inspect incident_public --format '{{.Internal}}'` → `true` | le réseau `public` est `internal: true`, pas de publication de port possible | confirmé, `internal` déplacé sur `backend` (A5) |
| 09h31 | `curl localhost:8081/health` → `front ok` mais `/products` → `502 Bad Gateway` | `docker compose logs front` → `connect() failed (111: Connection refused) while connecting to upstream, upstream: "http://127.0.0.1:3000/products"` | nginx proxy vers `localhost`, qui est le conteneur nginx lui-même | confirmé, `proxy_pass http://api:3000` (A6) |
| 09h36 | toujours 502, `api` en `Restarting` | `docker compose logs api` → `Error: Cannot find module '/app/server.js'` | `command: node server.js` alors que le fichier est dans `src/` | confirmé, `command` supprimé (le `CMD` de l'image est bon) (A7) |
| 09h40 | api démarrée mais nginx toujours en 502 | `docker exec incident-api-1 netstat -tln` → `:::8080` | `PORT: 8080` alors que nginx et le healthcheck de l'image visent 3000 | confirmé, `PORT: 3000` (A8) |
| 09h44 | `/products` → 500, logs api : `getaddrinfo ENOTFOUND databse` | `docker exec incident-api-1 getent hosts databse` → rien, `getent hosts db` → rien non plus | 1) faute de frappe `databse` 2) l'api ne voit pas la base | confirmé les deux (A9, A10) |
| 09h50 | `getent hosts db` vide depuis l'api | `docker inspect incident-api-1 --format '{{json .NetworkSettings.Networks}}' \| jq 'keys'` → `["incident_public"]` ; `docker network inspect incident_backend --format '{{range .Containers}}{{.Name}} {{end}}'` → `incident-db-1` | l'api n'est que sur `public`, la base que sur `backend` | confirmé, api ajoutée à `backend` (A10) |
| 09h55 | `/ready` → `{"status":"not ready","checks":{"db":"ok","error":"..."}}` redis KO | `docker inspect incident-redis-1 --format '{{.HostConfig.NetworkMode}}'` → `host` | redis en `network_mode: host` : pas sur le réseau docker, pas de DNS `redis` | confirmé, redis sur `backend` (A11) |
| 10h01 | redis joignable mais `/ready` → `NOAUTH Authentication required` | `docker run --rm --network container:incident-api-1 nicolaka/netshoot nc -zv redis 6379` OK ; `docker compose exec redis redis-cli ping` → `NOAUTH` | `--requirepass r3dis` mais l'URL n'a pas de mot de passe | confirmé, `redis://:r3dis@redis:6379` (A12) |
| 10h08 | tout répond mais `db` en `unhealthy` par moments + logs pleins de `FATAL: role "postgres" does not exist` | `docker inspect incident-db-1 --format '{{json .State.Health}}' \| jq '.Log[-1]'` + `docker compose logs db` | healthcheck `pg_isready -U postgres` alors que l'utilisateur est `shop` | confirmé, `-U shop -d shop` (A13) |
| 10h12 | `docker compose ps` : front, api, redis sans état de santé | `docker compose ps --format '{{.Name}} {{.Status}}'` | pas de healthcheck sur front et redis, et front qui démarre avant l'api | healthchecks ajoutés, `depends_on: condition: service_healthy` (A14, A15) |
| 10h20 | `/products` → `X-Cache: MISS` puis `HIT` ; une des requêtes en 502 après `docker compose restart api` | `docker compose restart api && curl -i localhost:8081/products` | nginx a résolu `api` au démarrage et garde les anciennes IP | `resolver 127.0.0.11` + variable dans `proxy_pass` (A16) |
| 10h31 | OK : catalogue renvoyé, `X-Cache: HIT` au 2e appel, tout `healthy` | voir plus bas | | résolu |

Vérification finale :

```
$ docker compose up -d --build --wait
$ docker compose ps --format 'table {{.Name}}\t{{.Status}}'
NAME               STATUS
incident-api-1     Up 40 seconds (healthy)
incident-api-2     Up 40 seconds (healthy)
incident-db-1      Up 52 seconds (healthy)
incident-front-1   Up 30 seconds (healthy)
incident-redis-1   Up 52 seconds (healthy)

$ curl -si localhost:8081/products | grep -i x-cache
X-Cache: MISS
$ curl -si localhost:8081/products | grep -i x-cache
X-Cache: HIT
$ curl -s localhost:8081/products | jq length
5
```

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie |
|---|-------------------|----------|------------|----------|
| A1 | compose / api | `container_name: api` avec `deploy.replicas: 2` | suppression de `container_name` | cycle de vie |
| A2 | compose / api | contexte de build `../../tp04-compose-entreprise/solution/apps/shopapi` inexistant | `../tp04-compose-entreprise/apps/shopapi` | config |
| A3 | compose / db | chemin de `init.sql` faux : docker crée un **dossier** vide à la place, la base démarre sans tables | `../tp04-compose-entreprise/db/init.sql` (et `down -v` pour réinitialiser) | stockage |
| A4 | compose / front | bind mount du dossier `./nginx` sur le fichier `default.conf` | `./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro` | stockage |
| A5 | compose / networks | `public` en `internal: true` (pas de port publié possible) et `backend` exposé | `public` normal, `backend` `internal: true` | réseau |
| A6 | default.conf | `proxy_pass http://localhost:3000` (localhost = le conteneur nginx) | `http://api:3000` via le DNS docker | réseau |
| A7 | compose / api | `command: node server.js` (fichier dans `src/`) | `command` supprimé, on garde le `CMD` de l'image | config |
| A8 | compose / api | `PORT: 8080` alors que nginx et le healthcheck utilisent 3000 | `PORT: 3000` | config |
| A9 | compose / api | `DATABASE_URL` sur l'hôte `databse` (typo) | `db` | config |
| A10 | compose / api | api seulement sur `public`, ne peut pas joindre db/redis | api sur `public` + `backend` | réseau |
| A11 | compose / redis | `network_mode: host` : pas de DNS docker, et le port 6379 ouvert sur l'hôte | redis sur `backend` | réseau / sécurité |
| A12 | compose / api | `REDIS_URL` sans mot de passe alors que `--requirepass` | `redis://:r3dis@redis:6379` | config |
| A13 | compose / db | healthcheck `pg_isready -U postgres` (rôle inexistant, logs pollués) | `pg_isready -U shop -d shop` | config |
| A14 | compose / front | `depends_on: [api]` sans condition : nginx démarre avant que l'api soit prête | `condition: service_healthy` | cycle de vie |
| A15 | compose / front, redis, api | pas de healthcheck (front, redis) ; l'api ne dépend pas de redis | healthchecks partout + `depends_on redis healthy` | cycle de vie |
| A16 | default.conf | nginx résout `api` une seule fois au démarrage, les IP changent si l'api redémarre | `resolver 127.0.0.11 valid=10s` + `proxy_pass $variable` | réseau |
| A17 | compose | aucune politique `restart` | `restart: unless-stopped` | cycle de vie |
| A18 | compose | mots de passe en clair (`shop`, `r3dis`) dans le fichier versionné | non corrigé pendant l'incident (hors périmètre), à passer en `secrets:` comme au TP04 | sécurité |

Note sur A3 : quand la source d'un bind mount n'existe pas, docker (pas compose en syntaxe longue) crée un dossier
vide à sa place. Postgres voit `init.sql/` comme un dossier et l'ignore. En plus, comme le volume `pgdata` avait déjà
été initialisé lors des essais précédents, les scripts d'init ne sont de toute façon pas rejoués : il a fallu
`docker compose down -v` (OK en préprod, données de test).

## Pourquoi ça n'a pas été détecté avant ?

- le compose a été modifié et poussé directement, sans revue ni test : personne n'a lancé `docker compose up` jusqu'au
  bout, et `docker compose config` ne détecte qu'une partie des erreurs (pas les chemins, pas les ports, pas le DNS) ;
- pas de healthchecks : même démarrés, les services ne disaient pas s'ils marchaient vraiment ;
- pas de smoke test (`/ready`, `/products`) après déploiement ;
- plusieurs erreurs se masquaient : tant que le front ne démarrait pas, on ne voyait pas que l'api ne trouvait pas la
  base, etc. Il a fallu remonter couche par couche ;
- la personne qui a fait la modif est partie juste après, sans prévenir ni laisser de note.

## Actions de prévention

1. **CI sur le compose** : `docker compose config --quiet` + lint (`dclint` / `yamllint`) + `docker compose up -d --wait`
   sur un runner + le `smoke-test.sh` du TP04 (`/ready`, cache HIT, commande confirmée). La merge request est bloquée
   si un service n'est pas `healthy`.
2. **Revue de code obligatoire** sur les fichiers d'infra (CODEOWNERS sur `compose*.yml` et `nginx/`) et pas de
   déploiement sans MR, en particulier pas de modif la veille de congés.
3. **Healthchecks + `depends_on: service_healthy` + `up --wait`** sur tous les services : le déploiement échoue
   tout de suite et clairement au lieu de laisser une stack à moitié morte.
4. bonus : supervision de la préprod (alerte si le front ne répond pas, cf. TP07) pour être prévenu avant les utilisateurs.

## Partie 1 - rappels réseau (notes)

```
$ docker run -d --name a alpine sleep 1d ; docker run -d --name b alpine sleep 1d
$ docker exec a ping -c1 b
ping: bad address 'b'
$ docker network create demo && docker network connect demo a && docker network connect demo b
$ docker exec a ping -c1 b
PING b (172.19.0.3): 56 data bytes
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.112 ms
$ docker exec a cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0
$ docker run --rm --network container:a nicolaka/netshoot ss -tlnp
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096      127.0.0.11:39125      0.0.0.0:*
```

- le bridge par défaut n'a pas de DNS (seulement l'ancien `--link`) ; un réseau utilisateur a le DNS embarqué
  `127.0.0.11` qui résout les noms de conteneurs, les noms de services compose et les alias ;
- `internal: true` : pas de passerelle vers l'extérieur ni de publication de port ;
- `host` : le conteneur partage la pile réseau de l'hôte (pas d'isolation, pas de DNS docker) ;
- `none` : juste `lo` ;
- `container:X` : partage la pile réseau de X (même IP, même `localhost`) : c'est comme ça qu'on debug avec netshoot
  sans rien installer dans l'image ;
- `-p 8081:80` = une règle DNAT iptables côté hôte vers l'IP du conteneur ; `expose` ne fait rien à part documenter.

## Bonus

### B1 - tcpdump

```
$ docker run --rm -it --network container:incident-api-1 nicolaka/netshoot tcpdump -i eth1 -A port 5432
...
SELECT id, name, price, stock FROM products ORDER BY id
...
```

La requête SQL et les résultats passent **en clair** sur le réseau docker. Un réseau bridge isole du reste mais ne
chiffre rien : n'importe quel conteneur qui partage le réseau (ou root sur l'hôte) peut écouter. Si c'est un
problème (multi-tenant, conformité) : TLS côté postgres (`ssl=on`, `sslmode=verify-full` côté client) ou réseau
overlay chiffré en swarm (`--opt encrypted`).

### B2 - alias réseau

```yaml
  db:
    networks:
      backend:
        aliases: [database]
```

et `DATABASE_URL=postgres://shop:shop@database:5432/shop`. Pour basculer sur une autre base (réplica promu, nouvelle
version) on déplace l'alias sur l'autre conteneur, l'appli ne change pas de config. C'est un peu un "CNAME" interne.

### B3 - `enable_icc=false`

```yaml
networks:
  backend:
    driver_opts:
      com.docker.network.bridge.enable_icc: "false"
```

Les conteneurs du réseau ne peuvent plus se parler entre eux (règle iptables DROP entre interfaces du bridge) : l'api
ne joint plus ni la base ni redis, la stack retombe en panne. Le DNS répond toujours (c'est le démon), c'est le trafic
qui est bloqué. Utile pour un réseau où les conteneurs ne doivent parler qu'à l'extérieur.

### B4 - conflit avec le VPN

Si le VPN d'entreprise route par exemple `172.16.0.0/12`, docker peut choisir `172.18.0.0/16` pour un nouveau réseau :
les paquets vers les machines du VPN dans cette plage partent dans le bridge docker → plus d'accès au VPN (ou
l'inverse). Solution dans `/etc/docker/daemon.json` :

```json
{
  "bip": "10.200.0.1/24",
  "default-address-pools": [
    { "base": "10.201.0.0/16", "size": 24 }
  ]
}
```
