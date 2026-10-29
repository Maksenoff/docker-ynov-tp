# TP04 - Stack Compose d'entreprise

## Démarrage rapide

```bash
make up            # genere secrets/db_password.txt si besoin, build, up --wait
make test          # smoke test
make tools         # + adminer sur http://adminer.localhost
make migrate M=002-add-sku.sql

cp .env.example .env
make prod-up       # images du registre, 2 replicas
```

Les apps viennent des TP01 (`apps/shopapi`) et TP02 (`apps/shop-worker`).

## 1. Critique du `docker-compose.yml` de départ

| # | Problème | Pourquoi c'est un problème |
|---|---|---|
| 1 | `version: '3'` | obsolète, ignoré par Compose v2 (warning). Ça donne l'impression qu'on est limité aux features de la v3 |
| 2 | `links:` | legacy, inutile depuis les réseaux utilisateur (le DNS par nom de service marche tout seul) |
| 3 | `image: postgres` / `image: redis` sans tag | = `latest`. Un pull peut faire passer de PG 16 à 17 et le volume devient illisible |
| 4 | ports 5432 et 6379 publiés | base et redis joignables depuis l'extérieur (et sans mot de passe pour redis) |
| 5 | port 3000 de l'API publié directement | pas de reverse proxy, impossible d'avoir plusieurs réplicas sur le même port |
| 6 | mots de passe en clair (`POSTGRES_PASSWORD: postgres`, dans les `DATABASE_URL`) | versionné dans git, visible dans `docker inspect` |
| 7 | compte superuser `postgres` / base `postgres` utilisés par l'appli | pas de moindre privilège |
| 8 | `sleep 10 && node ...` | ordre de démarrage au pif : trop court sur une machine lente, du temps perdu sinon. Et `sh -c` en PID 1 casse SIGTERM |
| 9 | un seul réseau (default) | tout le monde voit tout, la base est sur le même réseau que ce qui est exposé |
| 10 | aucun healthcheck | `depends_on` n'attend que le démarrage du conteneur, pas que la base accepte des connexions. `up --wait` impossible |
| 11 | pas de volume pour postgres | volume anonyme créé par l'image : perdu au premier `docker compose down -v` / `rm -v`, difficile à identifier |
| 12 | `restart: always` sur le worker seulement | incohérent : si la base crash au reboot elle ne revient pas mais le worker si (et boucle en erreur) |
| 13 | pas de limites CPU/mémoire | un service qui fuit peut faire tomber tout le serveur |
| 14 | pas de rotation des logs | json-file sans `max-size` remplit le disque |
| 15 | pas de nom de projet | le nom dépend du dossier → noms de volumes/réseaux différents selon où on clone |
| 16 | même fichier pour dev et prod | pas de distinction build local / image du registre, ports de debug en prod |

## 2. `compose.yml`

Voir [compose.yml](compose.yml). Points notables :

- `name: shop` → réseaux `shop_front` / `shop_back`, volumes `shop_pgdata` / `shop_redisdata` quel que soit le dossier ;
- `front` (traefik, api, adminer) et `back` en `internal: true` (api, worker, db, redis, adminer, migrate). Le worker
  et la base n'ont aucune route vers l'extérieur ;
- seul Traefik publie un port (80) ;
- healthchecks partout avec l'ancre `x-healthcheck-defaults` (merge `<<:`), `depends_on: condition: service_healthy` ;
- logs : ancre `x-logging` (json-file 10m x 3) ;

### DATABASE_URL à partir du secret

Postgres sait lire `POSTGRES_PASSWORD_FILE`, mais l'appli ne lit que `DATABASE_URL`. Sans toucher au code, on
surcharge l'entrypoint par un petit `sh -c` (ancre `x-db-url-entrypoint`) qui lit `/run/secrets/db_password`,
exporte `DATABASE_URL` puis fait `exec "$@"` : node/python restent PID 1 et reçoivent bien SIGTERM.

Attention : redéfinir `entrypoint` dans compose **remet `command` à vide** (comportement docker), d'où le `command`
explicite. Le mot de passe est en hexa (`make` le génère avec `openssl rand -hex 16`) pour ne pas avoir à l'encoder
dans l'URL. Et le fichier doit être lisible par l'uid de l'appli (1000 pour node, 10001 pour le worker) : hors swarm
un secret compose est juste un bind mount, les options `uid/gid/mode` sont ignorées.

La variable n'existe que dans le process, elle n'apparaît pas dans `docker inspect` (contrairement à `environment:`).

### Vérifications

```bash
docker compose config                  # fichier résolu, avec l'override dev
docker compose up -d --wait && docker compose ps
```

```
NAME             IMAGE                         SERVICE   STATUS
shop-api-1       localhost:5000/shopapi:dev    api       Up 20 seconds (healthy)
shop-db-1        postgres:16.4-alpine          db        Up 31 seconds (healthy)
shop-redis-1     redis:7.4-alpine              redis     Up 31 seconds (healthy)
shop-traefik-1   traefik:v3.1.4                traefik   Up 31 seconds (healthy)
shop-worker-1    localhost:5000/shop-worker:dev worker   Up 20 seconds (healthy)
```

`--wait` ne rend la main que quand tous les services sont `healthy` (ou sort en erreur).

## 3. Surcharge dev

[compose.override.yml](compose.override.yml), chargé automatiquement :

- bind mount `./apps/shopapi/src` sur `/app/src` + `node --watch` ;
- ports 3000 (api), 5432 (db), 8080 (dashboard traefik) ;
- `LOG_LEVEL=debug`.

Pour la base, `back` est `internal` : **un port publié sur un conteneur qui n'est que sur un réseau internal ne marche
pas** (pas de DNAT possible). L'override ajoute donc un réseau `dev` à la base, uniquement en dev.

Test du reload :

```
$ docker compose logs -f api
api-1  | {"level":30,...,"msg":"shopapi démarré"}
# modif de src/server.js
api-1  | Restarting 'src/server.js'
api-1  | {"level":30,...,"msg":"shopapi démarré"}
```

Sur Docker Desktop Windows avec le code sur le disque Windows (pas dans WSL), les événements inotify ne passent pas
toujours le bind mount → pas de reload. Solution : code dans le FS de WSL ou `docker compose watch` (bonus B1).

## 4. Surcharge prod

[compose.prod.yml](compose.prod.yml) :

```bash
docker compose -f compose.yml -f compose.prod.yml config
docker compose -f compose.yml -f compose.prod.yml up -d --wait
```

- `build: !reset null` supprime la clé `build` héritée du fichier de base (sinon compose essaierait de builder en
  prod). `!reset` vide une valeur, `!override` la remplace entièrement au lieu de la fusionner ;
- images `${REGISTRY}/shopapi:${VERSION}` depuis `.env`, avec `:?` pour planter si elles ne sont pas définies (B4) ;
- `deploy.replicas: 2` pour l'API, limites CPU/mémoire partout ;
- `read_only: true` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges` (ancre `x-hardening`). Postgres et redis
  récupèrent juste les capabilities dont leur entrypoint a besoin (chown + changement d'utilisateur) ;
- l'override dev n'est pas chargé quand on passe `-f` : pas de ports de debug, pas de dashboard.

Répartition de charge :

```
$ docker compose -f compose.yml -f compose.prod.yml ps api
shop-api-1   ...   Up (healthy)
shop-api-2   ...   Up (healthy)

$ for i in $(seq 6); do curl -s -H 'Host: api.localhost' localhost/health; done
$ docker compose -f compose.yml -f compose.prod.yml logs traefik | grep api.localhost | tail -6
... "GET /health HTTP/1.1" 200 ... "api@docker" "http://172.20.0.4:3000" ...
... "GET /health HTTP/1.1" 200 ... "api@docker" "http://172.20.0.5:3000" ...
... "GET /health HTTP/1.1" 200 ... "api@docker" "http://172.20.0.4:3000" ...
```

Le log d'accès traefik montre l'adresse du backend choisi : ça alterne entre les deux réplicas (round robin).
Les logs de chaque réplica (`docker compose logs api`, préfixe `api-1` / `api-2`) montrent aussi les requêtes réparties.

### `--scale api=3` puis `up -d`

```bash
docker compose -f compose.yml -f compose.prod.yml up -d --scale api=3   # 3 conteneurs, traefik en voit 3
docker compose -f compose.yml -f compose.prod.yml up -d                 # retour à 2
```

Le `--scale` n'est pas mémorisé : au `up -d` suivant compose réconcilie avec le fichier (`deploy.replicas: 2`) et
supprime le 3e conteneur (`shop-api-3`). La source de vérité c'est le fichier, pas la dernière commande.
Traefik retire le conteneur tout seul (provider docker).

## 5. Outillage

- [Makefile](Makefile) : `up`, `down`, `tools`, `prod-up`, `migrate M=...`, `test`, `config`, `clean` ;
- [smoke-test.sh](smoke-test.sh) : `/ready` (db + redis ok), `/products` deux fois (`X-Cache: HIT` au 2e), création
  de commande puis attente que le worker la passe en `confirmed` (lecture en base).

```
$ make test
-- /ready
  [ok] db et redis ok
-- /products et cache redis
  [ok] X-Cache: HIT
-- commande
  [ok] commande creee (pending)
  [ok] commande confirmee par le worker
smoke test ok
```

## Bonus

### B1 - `docker compose watch`

```yaml
  api:
    develop:
      watch:
        - action: sync+restart
          path: ./apps/shopapi/src
          target: /app/src
        - action: rebuild
          path: ./apps/shopapi/package.json
```

`sync` copie les fichiers modifiés dans le conteneur (pas de bind mount, donc pas de souci de perfs/inotify sur
Docker Desktop), `sync+restart` redémarre en plus le conteneur, `rebuild` reconstruit l'image et recrée le conteneur
(utile quand les deps changent, un sync ne servirait à rien car `npm ci` est dans l'image).

### B2 - TLS local

```bash
mkcert -install && mkcert -cert-file certs/local.pem -key-file certs/local-key.pem "*.localhost" localhost
```

Entrypoint `websecure` (:443) dans traefik, fichier de config dynamique `tls.certificates` monté, et sur l'entrypoint
`web` : `TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO=websecure` +
`..._SCHEME=https`. Les routers passent sur `entrypoints: websecure` avec `tls: "true"`.

### B3 - adminer et le réseau internal

Oui, adminer est joignable via Traefik. Adminer est sur **deux** réseaux : `back` (internal, pour parler à la base) et
`front` (normal). Traefik est sur `front` et route vers l'IP d'adminer sur `front`
(`TRAEFIK_PROVIDERS_DOCKER_NETWORK=shop_front`). `internal` empêche juste le réseau `back` d'avoir une passerelle vers
l'extérieur, ça n'empêche pas un conteneur d'être aussi sur un autre réseau. C'est exactement le même principe que l'API.
Par contre ça veut dire qu'adminer est un pont vers la base : en prod on ne lance pas le profil `tools`, ou alors
derrière une auth (middleware basicauth traefik) / IP allowlist.

### B4 - variables obligatoires

```
$ docker compose -f compose.yml -f compose.prod.yml config
error while interpolating services.api.image: required variable REGISTRY is missing a value: REGISTRY doit etre defini
```

### B5 - `include:` / publish

`include:` permet d'importer un autre fichier compose (avec son propre dossier de projet et son `.env`) :

```yaml
include:
  - path: ../observability/compose.yml
```

Chaque équipe maintient son morceau (par ex. la stack d'observabilité du TP07) et on l'inclut, contrairement à
`-f` qui fusionne les fichiers (et les chemins relatifs sont résolus par rapport au premier fichier).
`docker compose publish` pousse le compose comme artefact OCI dans un registre, on peut ensuite faire
`docker compose -f oci://registry.local:5000/shop-stack:1.4.2 up`.
