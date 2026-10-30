# TP09 - CI/CD et déploiement sans interruption

## 1. Le dépôt

[shop/](shop/) est le dépôt assemblé comme demandé : apps des TP01/TP02, stack compose du TP04, `release-gate.sh`
du TP03. Dans la vraie vie c'est un repo à part (le workflow doit être à la racine dans `.github/workflows` pour
que GitHub l'exécute), ici il est dans un sous-dossier pour garder tous les TP ensemble :

```bash
cp -r shop ~/shop && cd ~/shop && git init && git add -A && git commit -m "import"
gh repo create shop --private --source . --push
```

Ajouts par rapport au TP04 :

- [.github/workflows/ci.yml](shop/.github/workflows/ci.yml) + action composite [.github/actions/deploy](shop/.github/actions/deploy/action.yml) ;
- [deploy/rolling-update.sh](shop/deploy/rolling-update.sh), [deploy/measure-downtime.sh](shop/deploy/measure-downtime.sh) ;
- [ci-local.sh](shop/ci-local.sh) : le même pipeline en local contre le registre du TP03 ;
- dans `compose.yml` : middleware retry Traefik, healthcheck Traefik plus rapide, `stop_grace_period: 15s` ;
- [compose.swarm.yml](shop/compose.swarm.yml) pour le bonus B1.

## 2. Le pipeline

| Événement | Jobs |
|---|---|
| pull request | `lint` (hadolint récursif, `docker compose config` base + prod) → `build` : stage `test` (lint + tests dans l'image), build multi-arch **sans push** |
| push sur `main` | idem + push `sha-<7 car>` sur GHCR → trivy bloquant (HIGH/CRITICAL corrigeables + secrets) → signature cosign keyless → `deploy-preprod` |
| tag `v*` | idem avec les tags `1.4.2` et `1.4` en plus → `deploy-prod` (environment `production` avec reviewers obligatoires) |

Points imposés :

- **`docker/metadata-action`** : calcule les tags (`type=sha`, `type=semver`, `type=ref,event=pr`), `latest`
  désactivé (`flavor: latest=false`, cf. politique du TP03) et génère les labels OCI (`source`, `revision`,
  `version`, `created`...) ;
- **cache `type=gha`**, un scope par image pour que l'api et le worker ne s'écrasent pas, `mode=max` ;
- **multi-arch** `linux/amd64,linux/arm64` avec QEMU ;
- **matrice** api / worker ;
- **secret de build** : `pip.conf` généré depuis le secret GitHub `PIP_INDEX_URL` dans `$RUNNER_TEMP`, passé en
  `secret-files` (jamais dans un `build-arg`) ;
- **provenance** `mode=max` + **sbom** : attestations attachées à l'image dans GHCR.

### Signature keyless

`permissions: id-token: write` permet au job de demander un token OIDC à GitHub. `cosign sign` l'échange contre un
certificat Fulcio valable 10 min qui contient l'identité du workflow
(`https://github.com/<owner>/shop/.github/workflows/ci.yml@refs/heads/main`), signe, et publie dans Rekor. Aucune
clé à stocker.

Côté déploiement, l'action `deploy` refuse de continuer si :

```bash
cosign verify \
  --certificate-identity-regexp "^https://github.com/<owner>/shop/.github/workflows/ci.yml@" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/<owner>/shopapi:sha-3f1c9a0
```

échoue. Une image poussée à la main, ou par un autre repo, ou dont le scan trivy a échoué (le job s'arrête avant
la signature), ne peut pas être déployée.

### Sans compte GitHub

```bash
./ci-local.sh            # comme une PR
./ci-local.sh main       # + push sha-xxx sur registry.local:5000, gate, signature (clé du TP03), rolling update
./ci-local.sh tag v1.4.3 # + tags semver, confirmation manuelle avant la prod
act pull_request         # le vrai workflow dans des conteneurs (nektos/act)
```

## 3. Déploiement distant

```bash
docker context create preprod --docker "host=ssh://deploy@preprod.local"
docker --context preprod ps
DOCKER_CONTEXT=preprod docker compose -f compose.yml -f compose.prod.yml up -d --wait
```

Le client docker parle au daemon distant à travers SSH (il lance `docker system dial-stdio` sur le serveur).
Pas de port 2375 ouvert, pas de TLS docker à gérer, c'est l'authentification SSH qui protège.

Prérequis côté serveur :

- docker + plugin compose installés ;
- un utilisateur `deploy`, dans le groupe `docker` (attention : équivalent root sur ce serveur), avec seulement la
  clé publique de la CI dans `authorized_keys` (idéalement restreinte : `restrict,command=...` impossible ici car
  docker a besoin de `dial-stdio`, donc on restreint plutôt par IP avec `from="..."`) ;
- l'empreinte du serveur dans le secret `DEPLOY_KNOWN_HOSTS` côté CI (sinon `StrictHostKeyChecking` bloque, et
  il ne faut pas le désactiver) ;
- `docker login ghcr.io` fait une fois sur le serveur avec un token en lecture seule (`read:packages`) ;
- **le dossier `/opt/shop` avec `secrets/db_password.txt` (chmod 644, propriétaire deploy) et `db/init.sql`**.

**Piège du contexte distant** : compose tourne sur le runner, mais les bind mounts et les `secrets: file:` sont
montés par le daemon **du serveur**, avec le chemin absolu calculé sur le runner. Donc le projet doit être au même
chemin des deux côtés : l'action copie le checkout dans `/opt/shop` sur le runner, et le serveur a son `/opt/shop`.
Les variables (`REGISTRY`, `VERSION`) sont interpolées côté runner, pas besoin de `.env` sur le serveur.

**Comment les secrets arrivent en prod** : jamais par git ni par la CI. Ils sont posés une fois sur le serveur par un
admin (ou par Ansible depuis un coffre type Vault / SOPS), dans `secrets/` hors du repo, et lus par les conteneurs
en fichier (`/run/secrets/...`). La CI n'a que la clé SSH de déploiement et le token de registre. Rotation : changer
le fichier sur le serveur + `ALTER USER` en base + rolling update.

## 4. Zéro interruption

Terminal 1 : `./deploy/measure-downtime.sh 60` ; terminal 2 : le déploiement.

### Déploiement naïf

```
$ docker compose -f compose.yml -f compose.prod.yml up -d --force-recreate api
```

```
requetes : 6000
echecs   : 412
detail (seconde, code, nombre) :
  t+12s  code 502  x96
  t+13s  code 502  x100
  t+14s  code 502  x100
  t+15s  code 404  x64
  t+16s  code 000  x52
```

Compose arrête **tous** les réplicas puis les recrée : pendant le démarrage + healthcheck il n'y a plus aucun
backend. Traefik renvoie 502 tant qu'il connaît encore les anciens, puis 404 (plus de router du tout quand il n'y a
plus de conteneur), et quelques timeouts (000).

### Rolling update

```
$ VERSION=sha-7d41c2e ./deploy/rolling-update.sh
== deploiement de api en sha-7d41c2e
actuel : registry.local:5000/shopapi:sha-3f1c9a0 -> cible : registry.local:5000/shopapi:sha-7d41c2e
-- +1 replica neuf (total 3)
 ✔ Container shop-api-3  Healthy
-- arret de l'ancien 4be0a91c2d11 (SIGTERM, 15s max)
-- +1 replica neuf (total 3)
 ✔ Container shop-api-4  Healthy
-- arret de l'ancien 91c0e5f3a7b2 (SIGTERM, 15s max)
-- worker
 ✔ Container shop-worker-1  Healthy
== api en sha-7d41c2e sur 2 replicas (24 s)
```

```
requetes : 6000
echecs   : 0
```

### Rôle de chaque brique

| Brique | Rôle | Si on la retire |
|---|---|---|
| `HEALTHCHECK` (image) / `healthcheck` (compose) | dit à docker quand le conteneur est vraiment prêt | Traefik route vers un conteneur dont node n'écoute pas encore → 502 au démarrage de chaque réplica |
| `start_period` | ignore les échecs de healthcheck pendant le démarrage | conteneur marqué `unhealthy` (puis ignoré par Traefik) s'il démarre lentement ; avec un orchestrateur il serait tué en boucle |
| `--wait` | compose ne rend la main que quand le nouveau réplica est `healthy` | le script arrête l'ancien alors que le nouveau n'est pas prêt → coupure |
| Traefik (proxy) + provider docker | ne route que vers les conteneurs `healthy`, ajoute/retire les backends tout seul | avec un `-p 3000:3000` direct, impossible d'avoir deux versions en même temps sur le même port |
| healthcheck Traefik (`/health` toutes les 2s) | détecte un backend qui ne répond plus avant même l'event docker | un backend mort reste dans la rotation jusqu'à l'event `die` |
| middleware `retry` | une requête qui tombe sur un réplica qui vient de fermer son port est rejouée sur un autre | quelques 502 au moment exact du SIGTERM (fenêtre entre `server.close()` et le retrait par Traefik) |
| SIGTERM géré (TP01, `CMD` en forme exec) | `server.close()` : plus de nouvelles connexions, les requêtes en cours se terminent | SIGKILL après le timeout : requêtes en cours coupées net, `stop` qui prend 10 s |
| `stop_grace_period` / `stop -t 15` | laisse 15 s pour finir proprement avant SIGKILL | requêtes longues coupées |
| réplicas ≥ 2 | il y a toujours au moins un réplica qui sert pendant qu'on remplace l'autre | avec 1 seul réplica on peut quand même faire +1/-1, mais une panne du seul réplica = coupure |

## 5. Rollback

```
$ time VERSION=sha-3f1c9a0 ./deploy/rolling-update.sh
...
== api en sha-3f1c9a0 sur 2 replicas (19 s)
real    0m19.4s
```

~20 s, sans coupure (le rollback est juste un déploiement de l'ancienne version, mêmes garanties). Plus rapide
qu'un déploiement normal car l'image est encore sur l'hôte (`pull` instantané).

Ce qui rend le rollback possible :

- **tags immuables** (`sha-xxx`, semver) : `sha-3f1c9a0` est exactement l'image d'avant, bit pour bit ;
- l'image est toujours dans le registre (rétention du TP03 qui garde les N derniers) et souvent encore sur l'hôte ;
- la signature de l'ancienne image est toujours valide ;
- la config (compose) est dans git, on peut aussi redéployer l'ancien commit ;
- **la base est compatible** avec l'ancienne version du code.

**Migration non rétro-compatible** (renommer une colonne, en supprimer une) : là le rollback casse, l'ancien code
cherche une colonne qui n'existe plus. Et même sans rollback, pendant le rolling update les deux versions tournent en
même temps sur la même base. Il faut faire les migrations en **expand / contract** sur plusieurs déploiements :

1. *expand* : ajouter la nouvelle colonne (nullable), le code écrit dans les deux, lit l'ancienne ;
2. backfill des données, le code lit la nouvelle ;
3. *contract* : quand plus aucune version déployée n'utilise l'ancienne colonne, la supprimer.

Chaque étape est compatible avec la version d'avant, donc rollback possible à tout moment. La migration est lancée
**avant** le rolling update (`make migrate` / service `migrate` du TP04) et ne dépend pas de l'ordre.

## Bonus

### B1 - Swarm

[compose.swarm.yml](shop/compose.swarm.yml) :

```bash
docker swarm init
docker secret create db_password secrets/db_password.txt
REGISTRY=registry.local:5000 VERSION=sha-7d41c2e docker stack deploy -c compose.swarm.yml shop
docker service update --image registry.local:5000/shopapi:sha-3f1c9a0 shop_api   # rolling natif
```

`update_config: order: start-first, parallelism: 1` fait exactement ce que fait `rolling-update.sh`, avec en plus
`monitor` + `failure_action: rollback` : si le nouveau réplica tombe dans les 30 s, swarm revient tout seul à
l'ancienne version. Le routing mesh répartit déjà la charge, les secrets sont chiffrés dans le raft.

| | script | swarm |
|---|---|---|
| effort | ~50 lignes de bash à maintenir et tester | quelques lignes de YAML |
| robustesse | si le script plante au milieu, état intermédiaire à nettoyer à la main | état désiré maintenu par le moteur, rollback auto |
| changements | rien à changer côté serveur | `docker swarm init`, réseaux overlay, labels traefik sous `deploy`, pas de `depends_on` ni de `build` |

Pour un seul serveur, swarm reste plus robuste pour très peu d'effort.

### B2 - GitOps pull

```yaml
  watchtower:
    image: containrrr/watchtower:1.7.1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --interval 60 --label-enable --rolling-restart
```

Avantages : le serveur va chercher les mises à jour, **pas d'accès SSH entrant** depuis la CI (la CI n'a plus aucun
accès à la prod), marche derrière un NAT. Risques : watchtower suit un **tag** → il faut un tag mobile (`latest`,
`main`) donc on perd la traçabilité et l'immutabilité ; pas de gate (pas de vérif de signature, pas d'approbation),
watchtower a la socket docker (root), et pas de vrai rolling avec healthcheck. Une meilleure variante : un cron
côté serveur qui lit la version voulue dans un repo git de config, vérifie la signature et lance `rolling-update.sh`.

### B3 - publier le compose

```bash
docker compose -f compose.yml -f compose.prod.yml publish ghcr.io/<owner>/shop-stack:1.4.2
docker compose -f oci://ghcr.io/<owner>/shop-stack:1.4.2 up -d
```

La stack elle-même devient un artefact versionné et immuable : on sait exactement quelle config tournait avec quelle
version des images. Les bind mounts et fichiers locaux (`init.sql`, secrets) ne sont pas embarqués (compose refuse ou
prévient), il faut passer par `configs:` ou des images.

### B4 - tests d'intégration en CI

Job à ajouter après le build :

```yaml
  integration:
    needs: build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: |
          mkdir -p secrets && openssl rand -hex 16 > secrets/db_password.txt && chmod 644 secrets/db_password.txt
          docker compose up -d --build --wait
          ./smoke-test.sh
      - if: always()
        run: |
          docker compose logs
          docker compose down -v
```

Côté code, Testcontainers démarre un vrai postgres/redis dans les tests unitaires (au lieu de mocks) :
`new PostgreSqlContainer("postgres:16.4-alpine").start()` en Node, `PostgresContainer` en Python.
