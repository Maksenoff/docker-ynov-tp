# TP01 - Diagnostic de l'image legacy

Image analysée : `shopapi:legacy` construite avec le Dockerfile d'origine (gardé dans `shopapi/Dockerfile.legacy`).

```bash
docker build -f Dockerfile.legacy -t shopapi:legacy .
```

## Taille / performance

### 1. Image énorme (~1.2 Go)

```
$ docker image ls shopapi:legacy
REPOSITORY   TAG      IMAGE ID       CREATED         SIZE
shopapi      legacy   3f1c9a0e7b21   2 minutes ago   1.21GB
```

Impact : le registre sature, les pulls sont lents (déploiement, CI, autoscaling), plus de surface d'attaque.

### 2. Image de base `ubuntu:22.04` + Node installé à la main

`FROM ubuntu:22.04` puis install de Node via le script nodesource (`curl | bash`).
On réinvente ce que fait l'image officielle `node`, en plus gros et moins maîtrisé
(la version de node dépend du jour du build).

Impact : taille, pas de version épinglée de node, build non reproductible.

### 3. Paquets inutiles en prod

```
$ docker history shopapi:legacy --format '{{.Size}}\t{{.CreatedBy}}' | head
...
412MB   RUN /bin/sh -c apt-get install -y curl wget vim git build-essential python3
...
```

`vim`, `git`, `build-essential`, `python3`, `curl`, `wget` n'ont rien à faire dans une image qui lance juste `node`.
Impact : plusieurs centaines de Mo et autant de CVE potentielles en plus.

### 4. Cache apt jamais nettoyé + `apt-get update` dans une couche séparée

`RUN apt-get update` seul puis `RUN apt-get install` dans une autre couche : les listes apt restent dans l'image
(`/var/lib/apt/lists`, ~40 Mo) et si la couche `update` est en cache, le `install` peut utiliser des listes périmées.

Impact : taille + builds qui cassent "au hasard" plus tard.

### 5. Cache de build cassé à chaque changement de code

```dockerfile
COPY . /app
RUN npm install
```

Le `COPY . /app` copie tout le contexte avant le `npm install`. Le moindre changement (même un README)
change le checksum de la couche COPY donc toutes les couches suivantes sont rejouées.

```
$ echo "// commentaire" >> src/server.js
$ time docker build -f Dockerfile.legacy -t shopapi:legacy .
 => [7/8] COPY . /app
 => [8/8] RUN npm install           (rejoué)
real    0m41s
```

Impact : ~4 min par build en CI d'après le lead ops.

### 6. Dépendances de dev dans l'image

`npm install` sans `--omit=dev` installe `eslint` et `nodemon`, plus `npm install -g nodemon` en global.
`NODE_ENV=development` est forcé.

```
$ docker run --rm shopapi:legacy ls node_modules | grep -E 'eslint|nodemon'
eslint
nodemon
```

Impact : taille, CVE des outils de dev, express tourne en mode dev (stack traces, perfs moins bonnes).

### 7. `npm install` au lieu de `npm ci`, pas de lockfile

Pas de `package-lock.json` dans le repo, et `npm install` résout les `^` à chaque build.
Deux builds à une semaine d'écart n'ont pas forcément les mêmes versions.

Impact : build non reproductible.

## Sécurité

### 8. Le conteneur tourne en root

```
$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)
```

Impact : en cas de faille dans l'appli, l'attaquant est root dans le conteneur (et plus proche d'une évasion).

### 9. Secret en clair dans une variable d'environnement de l'image

```
$ docker run --rm shopapi:legacy env | grep -i -E 'secret|database'
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop
```

Aussi visible sans lancer le conteneur :

```
$ docker inspect shopapi:legacy --format '{{json .Config.Env}}'
["PATH=...","DEBIAN_FRONTEND=noninteractive","NODE_ENV=development","DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop"]
```

Impact : n'importe qui qui peut pull l'image a le mot de passe de la base de prod.

### 10. `.env` et dump de prod copiés dans l'image

Pas de `.dockerignore`, donc `COPY . /app` embarque tout :

```
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r-- 1 root root  183 .env
-rw-r--r-- 1 root root   22 .gitignore
-rw-r--r-- 1 root root  520 Dockerfile
-rw-r--r-- 1 root root   48 dump-prod-2024.sql
drwxr-xr-x 1 root root 4096 node_modules
-rw-r--r-- 1 root root  569 package.json
drwxr-xr-x 2 root root     4096 src
drwxr-xr-x 2 root root     4096 test

$ docker run --rm shopapi:legacy cat /app/.env
DATABASE_URL=postgres://shop:S3cret!@localhost:5432/shop
REDIS_URL=redis://localhost:6379
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE
```

Impact : fuite de clé AWS + données clients (RGPD). Ici le dump est simulé (48 octets) mais en vrai c'est 50 Mo de plus.

### 11. `curl | bash` sans vérification

`curl -fsSL https://deb.nodesource.com/setup_20.x | bash -` : on exécute un script distant en root au build,
sans checksum ni signature. Et sans `pipefail`, si le curl échoue le build continue.

Impact : supply chain (si le script est compromis, l'image l'est aussi).

## Exploitabilité

### 12. `CMD` en forme shell, pas d'arrêt propre

`CMD npm start` devient `/bin/sh -c "npm start"`. Le PID 1 est `sh`, qui ne relaie pas SIGTERM à npm, qui lui-même
ne le relaie pas bien à node. Le handler `shutdown()` de `server.js` n'est jamais appelé.

```
$ docker run -d --name legacy shopapi:legacy
$ docker exec legacy ps -o pid,args
PID   COMMAND
1     /bin/sh -c npm start
7     npm start
18    node src/server.js
$ time docker stop legacy
real    0m10.4s
```

Impact : docker attend les 10 s du timeout puis envoie SIGKILL. Rolling updates lents, connexions coupées brutalement.

### 13. Pas de HEALTHCHECK

```
$ docker inspect shopapi:legacy --format '{{json .Config.Healthcheck}}'
null
```

Impact : docker / compose / l'orchestrateur ne savent pas si l'appli répond vraiment, juste si le process existe.

### 14. Pas de labels OCI

```
$ docker inspect shopapi:legacy --format '{{json .Config.Labels}}'
{"org.opencontainers.image.ref.name":"ubuntu","org.opencontainers.image.version":"22.04"}
```

Les seuls labels sont ceux hérités d'ubuntu (et en plus ils mentent : version 22.04).
Impact : impossible de savoir quelle version / quel commit tourne en prod.

### 15. Pas de tests dans le build

Rien ne lance `npm test` ni `npm run lint`. Une image cassée peut être poussée.

## Sortie hadolint

```
$ hadolint Dockerfile.legacy
Dockerfile.legacy:4 DL3009 info: Delete the apt-get lists after installing something
Dockerfile.legacy:5 DL3008 warning: Pin versions in apt get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
Dockerfile.legacy:5 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
Dockerfile.legacy:5 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
Dockerfile.legacy:6 DL4006 warning: Set the SHELL option -o pipefail before RUN with a pipe in it. If you are using /bin/sh in an alpine image or if your shell is symlinked to busybox then consider explicitly setting your SHELL to /bin/ash, or disable this check
Dockerfile.legacy:6 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
Dockerfile.legacy:7 DL3008 warning: Pin versions in apt get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
Dockerfile.legacy:7 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
Dockerfile.legacy:7 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
Dockerfile.legacy:8 DL3016 warning: Pin versions in npm. Instead of `npm install <package>` use `npm install <package>@<version>`
Dockerfile.legacy:8 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
Dockerfile.legacy:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
```

## dive

`dive shopapi:legacy` donne une efficacité d'image autour de 90 % mais surtout montre que les plus grosses couches
sont l'install apt (build-essential, git, vim...) et `node_modules` avec les deps de dev.
On voit aussi `/app/dump-prod-2024.sql` et `/app/.env` dans la couche du `COPY . /app`.
