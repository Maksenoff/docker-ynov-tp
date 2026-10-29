# TP02 - Rapport BuildKit

Fichiers : [shop-worker/Dockerfile](shop-worker/Dockerfile), [docker-bake.hcl](docker-bake.hcl),
bonus uv : [shop-worker/Dockerfile.uv](shop-worker/Dockerfile.uv). L'ancien Dockerfile est gardé dans
`shop-worker/Dockerfile.legacy`.

Avant de builder :

```bash
cd shop-worker
cp pip.conf.example pip.conf     # pip.conf est dans le .gitignore et le .dockerignore
```

## 1. La fuite du secret avec ARG

```bash
docker build -f Dockerfile.legacy \
  --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple -t worker:leak . || true
```

Le build échoue (le registre n'existe pas) mais si il passait, le secret serait visible à au moins 3 endroits :

1. **`docker history --no-trunc worker:leak`** : chaque `RUN` qui suit un `ARG` est enregistré avec les ARG en
   préfixe de la commande :
   ```
   |1 PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple /bin/sh -c pip install -r requirements-dev.txt
   ```
2. **`docker inspect worker:leak`** : dans la config de l'image (`.ContainerConfig.Cmd` / historique dans le JSON de
   config) et dans les métadonnées de provenance si elles sont activées (`--provenance=mode=max` enregistre les build args).
3. **les couches** : pip écrit parfois l'URL d'index dans ses logs/cache (`/root/.cache/pip`, fichiers `direct_url.json`
   dans `site-packages/*.dist-info` pour certains paquets). Si on exporte l'image (`docker save` + tar), on peut les retrouver.
4. bonus : le cache de build local et le cache distant (`--cache-to`) contiennent aussi ces métadonnées.

Et même sans tout ça, `COPY . .` copiait le `pip.conf.example` (avec le vrai mot de passe) dans l'image.

Conclusion : un `ARG` n'est **pas** fait pour un secret.

## 2. Secret mount

```dockerfile
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    pip install -r requirements.txt
```

Le fichier est monté en tmpfs uniquement pendant ce `RUN`, il n'est écrit dans aucune couche et il n'apparaît pas dans
l'historique (seule la commande `pip install` y est).

```bash
docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
docker history --no-trunc worker:1.0 | grep -i -E 'secret|svc-ci|pip.conf'      # rien
docker run --rm worker:1.0 cat /etc/pip.conf
cat: /etc/pip.conf: No such file or directory
```

Le secret n'est pas non plus dans la clé de cache : changer le mot de passe ne relance pas le build (c'est voulu).
Si le secret n'est pas fourni le mount est juste absent (il est optionnel par défaut, `required=true` pour forcer
l'erreur), pip retombe alors sur pypi.org.

Alternatives :

- `--mount=type=ssh` : pour des deps dans un repo git privé (`pip install git+ssh://...`). On transmet l'agent ssh
  (`docker build --ssh default .`), la clé privée ne rentre jamais dans le build.
- `--secret id=TOKEN,env=TOKEN` côté CLI (lit la variable d'env de la CI au lieu d'un fichier) et
  `RUN --mount=type=secret,id=TOKEN,env=PIP_INDEX_URL` côté Dockerfile (dockerfile >= 1.10) pour l'exposer en variable
  d'env juste le temps du RUN. C'est ce que fait `Dockerfile.uv`.

## 3. Cache mount

```bash
time docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
docker builder prune -f
echo "requests==2.32.3" >> requirements.txt
time docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
```

| Build | Temps |
|---|---|
| 1er build (rien en cache) | ~28 s |
| après `builder prune -f` + ajout de `requests` | ~9 s |
| sans cache mount, même scénario | ~22 s |

> temps mesurés chez moi, ça dépend beaucoup du réseau

**Cache de couches** : le résultat d'une instruction est stocké tel quel. Si l'instruction ou ses entrées changent
(ici `requirements.txt`), la couche est jetée et le `pip install` repart de zéro.

**Cache mount** : un dossier persistant côté builder, monté pendant le `RUN`, qui n'est jamais dans l'image. Quand la
couche est rejouée, pip trouve les wheels déjà téléchargées dans `/root/.cache/pip` et ne télécharge que `requests`.

`docker builder prune -f` sans `-a` supprime le cache de couches "dangling" mais garde les cache mounts
(type `exec.cachemount`) tant qu'ils servent. `docker builder prune -af` les supprime.

`--no-cache` : ignore le cache de couches (tout est rejoué) mais **les cache mounts sont toujours utilisés**.
Donc pip retrouve quand même ses wheels.

## 4. Multi-architecture

```bash
docker buildx create --name shop --driver docker-container --use
docker buildx inspect --bootstrap
docker buildx build --platform linux/amd64,linux/arm64 \
  --secret id=pipconf,src=pip.conf -t localhost:5000/shop-worker:1.0 --push .
docker buildx imagetools inspect localhost:5000/shop-worker:1.0
```

```
Name:      localhost:5000/shop-worker:1.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:...

Manifests:
  Name:        localhost:5000/shop-worker:1.0@sha256:...
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64

  Name:        localhost:5000/shop-worker:1.0@sha256:...
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/arm64

  Name:        localhost:5000/shop-worker:1.0@sha256:...
  Platform:    unknown/unknown
  Annotations: vnd.docker.reference.type: attestation-manifest
```

| Build | Temps |
|---|---|
| amd64 seul | ~30 s |
| amd64 + arm64 (QEMU) | ~2 min 30 |

**Pourquoi `--push` ou `-o` est obligatoire** : le store d'images classique du daemon docker (sans le containerd image
store) ne sait stocker qu'une image par tag pour une seule plateforme. Un résultat multi-plateforme doit donc partir
quelque part qui sait stocker un index : un registre (`--push`) ou un fichier OCI (`-o type=oci,dest=worker.tar`).
Sinon buildx garde le résultat dans le cache du builder et affiche un warning.

**Le manifest list (image index)** : c'est un petit JSON qui liste un manifeste par plateforme (digest + `os/arch`).
Au `docker pull`, le client lit l'index et prend le manifeste correspondant à sa plateforme. Avec buildx il y a aussi
les manifestes d'attestation (provenance, `unknown/unknown`).

**`TARGETARCH` pour le cache** : BuildKit définit automatiquement `TARGETARCH` (`amd64`, `arm64`) pour chaque
plateforme. En le déclarant (`ARG TARGETARCH`) on l'utilise dans l'id du cache mount :
`--mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH}`. Sinon les deux builds parallèles partagent le même
cache, se marchent dessus (verrou) et mélangent des wheels de deux archis.

**Pourquoi arm64 est lent sur amd64** : il n'y a pas de CPU arm, chaque instruction arm64 est émulée par QEMU
(binfmt_misc) en espace utilisateur, c'est 5 à 20 fois plus lent, surtout quand il faut compiler (wheels sans binaire).
Alternatives :

- des builders natifs : ajouter un noeud arm64 au builder
  (`docker buildx create --name shop --append --platform linux/arm64 ssh://user@runner-arm64`), chaque plateforme est
  buildée sur sa vraie machine ;
- runners CI arm64 natifs (GitHub `ubuntu-24.04-arm`, Graviton) puis fusion des manifestes avec
  `docker buildx imagetools create` ;
- cross-compilation dans le Dockerfile (`FROM --platform=$BUILDPLATFORM` pour le stage de build), surtout utile en Go.

## 5. Cache distant

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --secret id=pipconf,src=pip.conf \
  --cache-to type=registry,ref=localhost:5000/cache:worker,mode=max \
  --cache-from type=registry,ref=localhost:5000/cache:worker \
  -t localhost:5000/shop-worker:1.0 --push .
```

Le cache est stocké comme une "image" de cache dans le registre, n'importe quel runner peut le réutiliser.
Variantes en CI : `type=gha` (cache GitHub Actions, avec `url`/`token` fournis par l'action), `type=s3` (bucket),
`type=local` (dossier partagé), `type=inline` (dans l'image elle-même, mode min uniquement).

`mode=min` (défaut) : n'exporte que les couches de l'image finale. Ici les stages `builder` et `test` ne seraient pas
dans le cache, donc pas de réutilisation sur un autre runner.
`mode=max` : exporte les couches de **tous** les stages intermédiaires. Plus gros à pousser mais bien meilleur taux de
hit pour un multi-stage.

Les cache mounts ne sont **pas** exportés par `--cache-to`, ils restent locaux au builder.

## 6. bake

```bash
docker buildx bake --print
VERSION=1.0 GIT_SHA=$(git rev-parse --short HEAD) docker buildx bake worker-test
VERSION=1.0 docker buildx bake --set *.platform=linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') --load
```

- `_common` : plateformes et labels communs, hérité par `api` et `worker` (les maps `labels`/`args` sont fusionnées).
- `worker-test` hérite de `worker` mais change la cible en `test` et l'output en `cacheonly` : il valide sans exporter.
- `--load` ne marche qu'avec une seule plateforme (même raison qu'en 4), d'où le `--set *.platform=...`.
- `--print` affiche le JSON final résolu, pratique pour vérifier les variables sans lancer de build.

## Bonus

### B1 - build sans réseau

```bash
# 1er build normal : remplit le cache mount
docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
# ensuite, avec pip qui ne va que dans le cache
docker build --network=none --secret id=pipconf,src=pip.conf -t worker:offline .
```

Pour que ça marche il faut que pip n'essaie pas de contacter l'index : on peut ajouter `--no-index --find-links`
sur un dossier de wheels pré-téléchargé (`pip download -d wheels -r requirements.txt` puis monter ce dossier).
Avec juste le cache http de pip, pip essaie quand même de vérifier l'index, donc ça casse.

Utile pour : environnements air-gapped (défense, banque, santé), builds reproductibles et auditables (on sait
exactement ce qui est entré dans l'image), protection contre un paquet compromis publié entre deux builds.

### B2 - provenance et SBOM

```bash
docker buildx build --platform linux/amd64 --provenance=mode=max --sbom=true \
  --secret id=pipconf,src=pip.conf -t localhost:5000/shop-worker:1.0-attest --push .
docker buildx imagetools inspect localhost:5000/shop-worker:1.0-attest --format '{{json .Provenance}}' | jq '.SLSA.invocation'
docker buildx imagetools inspect localhost:5000/shop-worker:1.0-attest --format '{{json .SBOM}}' | jq '.SPDX.packages | length'
```

La provenance (SLSA) contient le contexte git, le Dockerfile, les images de base avec leur digest, les args.
Le SBOM liste les paquets (debian + python). C'est exactement ce qui sert au TP03 (scan, signature, attestation).
Les secrets montés n'apparaissent pas dans la provenance (contrairement aux ARG en `mode=max`).

### B3 - uv

```bash
echo "https://pypi.org/simple" > uv_index.txt
docker build -f Dockerfile.uv --secret id=uv_index,src=uv_index.txt -t worker:uv .
```

| | pip | uv |
|---|---|---|
| 1er build | ~28 s | ~12 s |
| rebuild avec cache mount | ~9 s | ~2 s |

Le cache d'uv est dans `/root/.cache/uv`. `UV_LINK_MODE=copy` évite un warning car le cache (mount) et le venv ne sont
pas sur le même système de fichiers, uv ne peut pas faire de hardlinks.
