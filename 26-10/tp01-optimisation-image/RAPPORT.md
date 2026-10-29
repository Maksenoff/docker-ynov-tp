# TP01 - Rapport

## 2. Invalidation du cache

```bash
time docker build -f Dockerfile.legacy -t shopapi:legacy .
echo "// commentaire" >> src/server.js
time docker build -f Dockerfile.legacy -t shopapi:legacy .
```

Docker réutilise une couche tant que l'instruction ET ses entrées n'ont pas changé. Pour un `COPY`, l'entrée c'est le
checksum des fichiers copiés. Dans le legacy on fait `COPY . /app` (tout le contexte) juste avant `RUN npm install` :
modifier `server.js` change le checksum du COPY, donc la couche est invalidée et **toutes celles d'après aussi**,
y compris le `npm install`, alors que `package.json` n'a pas bougé.

Ordre idéal des couches (du moins souvent modifié au plus souvent modifié) :

```
1. FROM node:20.17.0-alpine3.20          (image de base épinglée)
2. WORKDIR /app
3. COPY package.json package-lock.json   (change seulement quand on ajoute/maj une dep)
4. RUN npm ci --omit=dev                 (rejoué seulement si 3 change)
5. COPY src ./src                        (change à chaque commit)
6. USER / HEALTHCHECK / CMD              (métadonnées, pas de coût)
```

Avec le nouveau Dockerfile, après le même `echo >> src/server.js` seuls `COPY src`, les tests et les couches finales
sont rejoués, les étapes `npm ci` sortent du cache (`CACHED`).

## 3. Dockerfile final

Voir [shopapi/Dockerfile](shopapi/Dockerfile). Choix :

- `node:20.17.0-alpine3.20` : image officielle, version complète épinglée (pas juste `20-alpine` qui bouge).
  Alpine suffit ici car aucune dépendance native (pas de module compilé, `pg` est en pur JS).
- 4 stages : `base` (manifestes npm) → `deps` (deps de prod) / `test` (toutes les deps + lint + tests) → `runtime`.
- `npm ci` avec le `package-lock.json` (ajouté au repo) pour un build reproductible.
- cache mount `/root/.npm` pour ne pas retélécharger les tarballs même quand la couche est invalidée.
- le `runtime` copie `package.json` depuis le stage `test` : BuildKit ne construit que les stages nécessaires à la
  cible, sans ça le stage `test` serait ignoré lors d'un `docker build` normal. Là, si les tests échouent, l'image
  n'est pas produite.
- `node_modules` et `src` appartiennent à root et sont en lecture seule pour l'utilisateur `node` : l'appli ne peut
  pas modifier son propre code.
- `USER node` (uid 1000, fourni par l'image officielle).
- `CMD ["node", "src/server.js"]` en forme exec : node est PID 1 et reçoit directement SIGTERM.
- `.dockerignore` : `.env`, `*.sql`, `.git`, `node_modules` locaux ne sont jamais envoyés au daemon.
- `DATABASE_URL` n'est plus dans l'image, elle est passée au runtime (`-e`, compose, secret).

```bash
docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo local) -t shopapi:1.4.2 .
docker build --target test -t shopapi:test .
```

## 4. Conformité

```
$ docker image ls shopapi
REPOSITORY   TAG      IMAGE ID       CREATED          SIZE
shopapi      1.4.2    8b2d4e61c0af   10 seconds ago   ~150MB
shopapi      legacy   3f1c9a0e7b21   20 minutes ago   ~1.2GB

$ docker run --rm shopapi:1.4.2 id
uid=1000(node) gid=1000(node) groups=1000(node)

$ docker run --rm shopapi:1.4.2 ls /app
node_modules
package.json
src

$ docker inspect shopapi:1.4.2 --format '{{json .Config.Labels}}' | jq
{
  "org.opencontainers.image.description": "API catalogue produits Shop SAS",
  "org.opencontainers.image.revision": "<sha court du commit>",
  "org.opencontainers.image.source": "https://github.com/Maksenoff/docker-ynov-tp",
  "org.opencontainers.image.title": "shopapi",
  "org.opencontainers.image.vendor": "Shop SAS",
  "org.opencontainers.image.version": "1.4.2"
}

$ docker run -d --name api -p 3000:3000 shopapi:1.4.2
$ sleep 6 && docker inspect api --format '{{.State.Health.Status}}'
healthy

$ curl -s localhost:3000/products | jq
[
  { "id": 1, "name": "Clavier mécanique", "price": 89.9, "stock": 12 },
  { "id": 2, "name": "Écran 27\"", "price": 249, "stock": 4 },
  { "id": 3, "name": "Souris sans fil", "price": 29.5, "stock": 40 }
]

$ time docker stop api
real    0m0.4s
```

### Pourquoi `docker stop` passe de 10 s à moins d'1 s

`docker stop` envoie SIGTERM au PID 1 du conteneur, attend 10 s (par défaut) puis envoie SIGKILL.

- legacy : PID 1 = `/bin/sh -c npm start`. `sh` en PID 1 n'a pas de handler pour SIGTERM et le noyau ignore les
  signaux sans handler pour le PID 1 d'un namespace. Le signal n'arrive jamais à node → on attend les 10 s → SIGKILL.
- nouvelle image : PID 1 = `node`, qui a un handler `process.on('SIGTERM')` → `server.close()` → `exit(0)` immédiat.

Si on ne pouvait pas éviter un shell, il faudrait `exec` dans le script ou `docker run --init` (tini en PID 1).

## 5. Avant / après

| | legacy | 1.4.2 |
|---|---|---|
| Image de base | `ubuntu:22.04` + nodesource | `node:20.17.0-alpine3.20` |
| Taille | ~1.2 Go | ~150 Mo |
| Nombre de couches (`docker history`, hors 0B) | 9 | 8 (dont 4 de l'image node) |
| Rebuild après modif de `src/server.js` | ~40 s (npm install rejoué) | ~3 s (deps en cache, seuls tests + COPY src) |
| Utilisateur | root (uid 0) | node (uid 1000) |
| Secrets dans l'image | `DATABASE_URL` en ENV, `.env`, dump SQL | aucun |
| Deps de dev | oui (eslint, nodemon x2) | non |
| Tests au build | non | oui (stage `test`) |
| HEALTHCHECK | non | oui (`/health`) |
| Labels OCI | non | version, revision, source, title, vendor |
| `docker stop` | ~10.4 s (SIGKILL) | ~0.4 s (SIGTERM géré) |

> Les tailles et temps sont ceux de ma machine, ils varient selon le réseau et le CPU.

```
$ hadolint Dockerfile
$ echo $?
0
```

## Bonus

### B1 - distroless

Voir [shopapi/Dockerfile.distroless](shopapi/Dockerfile.distroless).

```bash
docker build -f Dockerfile.distroless -t shopapi:1.4.2-distroless .
```

Compromis :

- plus petit et surtout beaucoup moins de paquets (pas de shell, pas de gestionnaire de paquets, pas de busybox) donc
  beaucoup moins de CVE et un attaquant ne peut pas faire grand chose même s'il exécute du code ;
- mais **pas de shell** : `docker exec -it api sh` ne marche pas. Pour debug il faut l'image `:debug` (qui a busybox)
  ou un conteneur sidecar (`docker run --rm -it --pid container:api --network container:api nicolaka/netshoot`) ;
- pas de `wget`/`curl` pour le healthcheck : on utilise node lui-même avec `http.get` en forme exec
  (`/nodejs/bin/node -e ...`), la forme shell `CMD-SHELL` est impossible sans `/bin/sh` ;
- distroless est basé sur debian (glibc), donc les deps sont installées dans un stage `bookworm-slim`
  et pas alpine (musl), sinon un module natif compilé sur alpine ne marcherait pas.

### B2 - --no-cache vs cache mount

```bash
docker builder prune -af
time docker build --no-cache -t shopapi:nocache .                  # télécharge tout depuis le registre npm
# on modifie package.json (ajout d'une dep) pour invalider la couche npm ci
time docker build -t shopapi:cachemount .                          # npm ci rejoué mais tarballs dans /root/.npm
```

| Cas | Temps |
|---|---|
| `--no-cache`, cache mount vide | ~25 s |
| couche npm invalidée, cache mount rempli | ~8 s |
| rien de changé (cache de couches) | ~1 s |

`--no-cache` désactive le cache des couches mais **pas** le contenu des cache mounts : le `npm ci` est rejoué
mais trouve les paquets dans `/root/.npm`. Pour vraiment repartir de zéro il faut `docker builder prune`.
Le cache mount n'est jamais dans l'image finale.

### B3 - build reproductible

```bash
export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
docker buildx build --no-cache --build-arg SOURCE_DATE_EPOCH \
  --output type=oci,dest=build1.tar,rewrite-timestamp=true .
docker buildx build --no-cache --build-arg SOURCE_DATE_EPOCH \
  --output type=oci,dest=build2.tar,rewrite-timestamp=true .
sha256sum build1.tar build2.tar
```

Ce qui casse la reproductibilité :

- les dates : date de création de l'image dans la config, mtime des fichiers dans les couches (réglé par
  `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true`) ;
- les images de base par tag : `node:20.17.0-alpine3.20` peut être repoussé (patch de sécurité). Il faut épingler par
  digest `node:20.17.0-alpine3.20@sha256:...` ;
- les dépendances résolues au build : sans lockfile `npm install` prend la dernière version compatible ;
- `apk add` / `apt-get install` sans version épinglée ;
- les fichiers générés pendant le build qui contiennent des dates ou des chemins (cache npm, `.pyc`, logs) ;
- les attestations provenance (contiennent l'heure du build) : `--provenance=false` pour comparer.
