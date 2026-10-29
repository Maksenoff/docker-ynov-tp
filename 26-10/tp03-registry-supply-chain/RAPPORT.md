# TP03 - Registre privé et supply chain

## 1. Registre sécurisé

Fichiers dans [registry/](registry/) :

- `gen-certs.sh` : CA interne + certificat serveur (SAN `registry.local`, `registry`, `localhost`, `127.0.0.1`) ;
- `gen-htpasswd.sh` : comptes `ci` et `dev` en bcrypt (`htpasswd -B` depuis l'image `httpd`) ;
- `config.yml` : TLS, auth htpasswd, `storage.delete.enabled: true`, health check du storage, serveur de debug sur
  `:5050` (utilisé par le healthcheck) ;
- `mirror-config.yml` : 2e registre en mode `proxy` (pull-through cache de Docker Hub) ;
- `compose.yml` : registre (5000), mirror (5001), UI joxit (8082), volumes nommés, healthchecks, `restart: unless-stopped` ;
- `daemon.json` : à fusionner dans `/etc/docker/daemon.json` puis `systemctl restart docker`.

Mise en place :

```bash
cd registry
./gen-certs.sh
./gen-htpasswd.sh
sudo mkdir -p /etc/docker/certs.d/registry.local:5000
sudo cp certs/ca.crt /etc/docker/certs.d/registry.local:5000/ca.crt
echo '127.0.0.1 registry.local' | sudo tee -a /etc/hosts
docker compose up -d --wait
```

Validation :

```
$ curl -k https://registry.local:5000/v2/
{"errors":[{"code":"UNAUTHORIZED","message":"authentication required","detail":null}]}
$ curl -k -o /dev/null -w '%{http_code}\n' https://registry.local:5000/v2/
401

$ curl -k -u dev:dev-pull-2024 https://registry.local:5000/v2/_catalog
{"repositories":[]}

$ docker login registry.local:5000 -u ci
Password:
Login Succeeded

$ docker tag shopapi:1.4.2 registry.local:5000/shopapi:1.4.2 && docker push registry.local:5000/shopapi:1.4.2
The push refers to repository [registry.local:5000/shopapi]
...
1.4.2: digest: sha256:... size: 1989

$ docker pull alpine:3.20 && docker rmi alpine:3.20 && docker pull alpine:3.20
$ docker compose logs mirror | grep alpine
mirror-1  | ... "GET /v2/library/alpine/manifests/3.20 HTTP/1.1" 200 ...
$ curl -s localhost:5001/v2/_catalog
{"repositories":["library/alpine"]}
```

Le 2e pull est servi par le mirror (il apparaît dans son catalogue et ses logs), Docker Hub n'est contacté que pour
vérifier le manifeste (TTL de 168h dans la config).

Le `curl -k` ignore la vérif TLS, la vraie vérif c'est `curl --cacert certs/ca.crt https://registry.local:5000/v2/`.

### Limite : `dev` peut pousser

`htpasswd` ne fait que de **l'authentification** (qui es-tu), pas de **l'autorisation** (qu'as-tu le droit de faire).
Avec `registry:2`, tout compte valide peut push et supprimer. Le compte `dev` "pull only" n'est donc qu'une
convention. Pour vraiment restreindre il faut l'auth par token (`auth.token` + un serveur comme `cesanta/docker_auth`)
ou un reverse proxy qui bloque `PUT/POST/PATCH/DELETE` pour l'utilisateur `dev`.

### htpasswd suffit-il en entreprise ?

Non :

- pas de RBAC (cf. au dessus), pas de notion de projet/équipe ;
- pas de SSO (LDAP, OIDC), les comptes sont dans un fichier, il faut redémarrer/remonter pour en ajouter, pas
  d'expiration ni de rotation, pas de tokens par robot ;
- pas d'audit (qui a poussé quoi et quand) à part les logs bruts.

Ce qu'apportent Harbor, Nexus, Artifactory, ECR/ACR/GAR :

- **RBAC** par projet, comptes robots pour la CI, SSO ;
- **scan intégré** (Trivy dans Harbor) avec blocage du pull des images vulnérables ;
- **réplication** entre sites/régions et vers d'autres registres ;
- **quotas** par projet ;
- **immutabilité des tags** (on ne peut plus réécrire `1.4.2`) et règles de rétention ;
- vérification des signatures (cosign/notation), proxy cache intégré, garbage collection planifié, UI, webhooks.

## 2. API du registre

```bash
R=https://registry.local:5000
C="curl -fsS --cacert registry/certs/ca.crt -u ci:ci-push-2024"
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# depots
$C $R/v2/_catalog | jq -r '.repositories[]'
# tags
$C $R/v2/shopapi/tags/list | jq -r '.tags[]'
# digest d'un tag
$C -I -H "Accept: $ACCEPT" $R/v2/shopapi/manifests/1.4.2 | grep -i docker-content-digest
# suppression par digest (on ne peut PAS supprimer par tag)
D=$($C -I -H "Accept: $ACCEPT" $R/v2/shopapi/manifests/1.4.2 | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r')
$C -X DELETE $R/v2/shopapi/manifests/$D
# garbage collect (supprime les blobs plus référencés)
docker compose -f registry/compose.yml exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
```

Sans le bon header `Accept`, le registre renvoie un ancien format de manifeste (ou une erreur) et le digest n'est
pas celui que docker utilise.

**Deux tags sur le même manifeste** : la suppression se fait par digest, donc on supprime le manifeste lui-même, et
**tous les tags qui pointent dessus disparaissent** (par exemple supprimer `1.4.2` supprime aussi `1.4` si c'est le
même digest). Le `garbage-collect` ne libère l'espace des couches qu'à la fin, quand plus aucun manifeste ne les
référence. Le GC doit idéalement se faire registre en lecture seule (sinon risque de supprimer une couche en cours de push).

[retention.sh](retention.sh) : garde les N tags hors semver les plus récents (date `created` lue dans la config de
l'image), ne touche jamais aux tags semver ni aux tags cosign, et saute un tag si son digest est partagé avec un tag
semver (sinon on supprimerait la release avec). Dry-run par défaut :

```bash
REG_PASS=ci-push-2024 ./retention.sh shopapi 5
REG_PASS=ci-push-2024 DRY_RUN=0 ./retention.sh shopapi 5
```

## 3. Politique de tags

Voir [TAGGING.md](TAGGING.md).

## 4. SBOM, scan, signature

Tout en conteneur (pas besoin d'installer les outils) :

```bash
alias syft='docker run --rm -v /var/run/docker.sock:/var/run/docker.sock anchore/syft:v1.13.0'
alias trivy='docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.55.2'
alias cosign='docker run --rm --network host -v $PWD:/work -w /work -v ~/.docker:/docker:ro -e DOCKER_CONFIG=/docker -v $PWD/registry/certs/ca.crt:/ca.crt:ro -e SSL_CERT_FILE=/ca.crt -e COSIGN_PASSWORD ghcr.io/sigstore/cosign/cosign:v2.4.0'
```

```
$ syft shopapi:1.4.2 -o spdx-json > sbom.json ; jq '.packages | length' sbom.json
~250   (paquets alpine + modules npm)

$ trivy image --severity HIGH,CRITICAL --ignore-unfixed shopapi:1.4.2
shopapi:1.4.2 (alpine 3.20.x)
Total: 0 (HIGH: 0, CRITICAL: 0)

$ trivy image --severity HIGH,CRITICAL --ignore-unfixed shopapi:legacy
shopapi:legacy (ubuntu 22.04)
Total: plusieurs dizaines (HIGH: ..., CRITICAL: ...)

$ trivy image --scanners secret shopapi:legacy
/app/.env (secrets)
Total: 1 (HIGH: 0, CRITICAL: 1)
CRITICAL: AWS (aws-access-key-id)
  AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE
```

Oui, Trivy retrouve la clé AWS du TP01 dans `/app/.env`. Par contre le `DATABASE_URL` mis en `ENV` n'est pas vu par
le scanner de secrets des fichiers (il est dans la config de l'image, pas dans une couche) : c'est pour ça que
`release-gate.sh` est complémentaire des scans.

```bash
COSIGN_PASSWORD= cosign generate-key-pair
COSIGN_PASSWORD= cosign sign --key cosign.key --tlog-upload=false registry.local:5000/shopapi:1.4.2
cosign verify --key cosign.pub --insecure-ignore-tlog=true registry.local:5000/shopapi:1.4.2 | jq
COSIGN_PASSWORD= cosign attest --key cosign.key --tlog-upload=false --type spdxjson --predicate sbom.json registry.local:5000/shopapi:1.4.2
```

`--tlog-upload=false` / `--insecure-ignore-tlog` parce que c'est un registre privé : sinon cosign envoie la signature
au log de transparence public Rekor (avec le nom de l'image dedans).

Ce que ça crée dans le registre :

```
$ $C $R/v2/shopapi/tags/list | jq -r '.tags[]'
1.4.2
sha256-6b0c2e4f....sig
sha256-6b0c2e4f....att
```

Cosign ne modifie pas l'image : il pousse des artefacts OCI à côté, dans le même dépôt, avec un tag dérivé du
**digest** de l'image signée (`sha256-<digest>.sig` pour la signature, `.att` pour l'attestation).

**Retag + re-push d'une image modifiée sous le même tag** : le tag `1.4.2` pointe maintenant sur un nouveau digest.
La signature, elle, est attachée à l'ancien digest. `cosign verify ...:1.4.2` résout le tag vers le nouveau digest,
ne trouve pas de `sha256-<nouveau>.sig` → `no signatures found`. La signature **suit le digest, pas le tag**. C'est
justement ce qui protège : on ne peut pas remplacer une image signée sans que ça se voie.

## 5. Porte de release

[release-gate.sh](release-gate.sh) vérifie, dans l'ordre :

1. labels `org.opencontainers.image.version/revision/source` présents (et pas `unknown`) ;
2. `USER` défini et pas root/0 ;
3. `HEALTHCHECK` défini ;
4. pas de CVE HIGH/CRITICAL corrigeable (`trivy --ignore-unfixed --exit-code 1`) ;
5. pas de secret dans les couches (`trivy --scanners secret`).

Si une règle échoue → code 1. Sinon, avec `--push` : tag + push, récupération du **digest**, SBOM syft,
`cosign sign` et `cosign attest` sur le digest.

```
$ ./release-gate.sh shopapi:legacy
== shopapi:legacy
-- labels OCI
  [ok] org.opencontainers.image.version=22.04
  [KO] org.opencontainers.image.revision absent
  [KO] org.opencontainers.image.source absent
-- utilisateur
  [KO] l'image tourne en root (USER='')
-- healthcheck
  [KO] pas de HEALTHCHECK
-- CVE HIGH/CRITICAL corrigeables
  ...
  [KO] CVE HIGH/CRITICAL corrigeables (voir le tableau au dessus)
-- secrets
  ...
  [KO] secret detecte dans l'image
== REFUSE : 6 probleme(s)
$ echo $?
1

$ COSIGN_PASSWORD= ./release-gate.sh shopapi:1.4.2 --push registry.local:5000/shopapi:1.4.2
== shopapi:1.4.2
-- labels OCI
  [ok] org.opencontainers.image.version=1.4.2
  [ok] org.opencontainers.image.revision=3f1c9a0
  [ok] org.opencontainers.image.source=https://github.com/Maksenoff/docker-ynov-tp
-- utilisateur
  [ok] USER=node
-- healthcheck
  [ok] HEALTHCHECK ["CMD-SHELL","wget -qO- http://127.0.0.1:3000/health || exit 1"]
-- CVE HIGH/CRITICAL corrigeables
  [ok] aucune CVE HIGH/CRITICAL corrigeable
-- secrets
  [ok] aucun secret detecte
== ACCEPTE
-- push vers registry.local:5000/shopapi:1.4.2
...
== publie et signe : registry.local:5000/shopapi@sha256:...
```

Remarque : sur l'image legacy le label `version` passe (`22.04`) parce qu'il est hérité de l'image ubuntu. C'est une
limite du script : un label hérité de l'image de base "ment". Pour être plus strict on pourrait exiger que `version`
corresponde au tag poussé, ou que `source` pointe sur un repo de l'entreprise.

## Bonus

### B1 - scan continu

```bash
docker run -d --name trivy-server -p 4954:4954 -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.55.2 \
  server --listen 0.0.0.0:4954
# cote client : pas de base a telecharger, le serveur l'a deja
trivy image --server http://localhost:4954 shopapi:1.4.2
```

La base de vulnérabilités (~500 Mo) n'est téléchargée qu'une fois par le serveur (mise à jour toutes les 12h),
les postes et la CI ne font que demander. Pour du continu : re-scanner tous les jours les images **déjà en prod**
(une CVE peut sortir après le build), pas seulement au moment du build.

### B2 - keyless

```bash
cosign sign registry.local:5000/shopapi@sha256:...      # ouvre le navigateur, login GitHub
cosign verify --certificate-identity you@example.com --certificate-oidc-issuer https://github.com/login/oauth ...
```

Avantages : pas de clé privée à stocker/protéger/faire tourner, le certificat (Fulcio) dure 10 min et lie la
signature à une identité OIDC (compte GitHub, workflow GitHub Actions), tout est tracé dans Rekor (log public).
Inconvénients : dépendance à des services externes (Fulcio, Rekor) ou il faut les héberger soi-même, le nom de
l'image et l'identité du signataire sont publics dans Rekor, besoin d'accès Internet à la signature et à la vérif.

### B3 - policy as code

[verified-run.sh](verified-run.sh) : `cosign verify` puis `docker run` **par digest** (celui renvoyé par la
vérification). Si on relançait par tag, quelqu'un pourrait changer le tag entre la vérif et le run.
En vrai on ferait ça côté orchestrateur (Kyverno, Sigstore policy-controller, Connaisseur sur k8s).

```bash
./verified-run.sh registry.local:5000/shopapi:1.4.2 -d -p 3000:3000
```

### B4 - scanner le SBOM

```bash
trivy sbom sbom.json
```

Le SBOM est l'inventaire figé au moment du build. Quand une CVE sort 6 mois après (genre une faille dans `express`),
on peut re-scanner tous les SBOM archivés en quelques secondes sans re-pull ni re-analyser les images, et savoir
immédiatement quelles images en prod sont touchées. Ça marche même si l'image a été supprimée du registre.
