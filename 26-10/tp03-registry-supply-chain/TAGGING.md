# Politique de tags Shop SAS

## Tags produits par la CI

| Tag | Exemple | Quand | Immuable ? |
|---|---|---|---|
| semver complet | `shopapi:1.4.2` | release (tag git `v1.4.2`) | **oui**, jamais repoussé |
| sha git | `shopapi:sha-3f1c9a0` | chaque build de `main` | oui (un commit = un contenu) |
| semver mineur | `shopapi:1.4` | release, pointe sur le dernier patch | non, bouge à chaque patch |
| semver majeur | `shopapi:1` | release | non |
| branche | `shopapi:main`, `shopapi:feat-xyz` | chaque push | non, nettoyé par `retention.sh` |
| `latest` | | **jamais produit** | |

Règles :

- un tag semver complet ou un tag `sha-` n'est jamais réécrit. Si une image est cassée, on sort `1.4.3`, on ne
  repousse pas `1.4.2`. (Harbor/ECR/ACR ont une option "tag immutability" pour le forcer côté registre, avec
  `registry:2` c'est juste une règle de la CI.)
- les tags mobiles (`1.4`, `1`, `main`) servent aux devs et à la préprod, pas à la prod ;
- les tags `sha256-<digest>.sig` / `.att` sont créés par cosign, la rétention ne doit pas les toucher.

## Pourquoi `latest` est interdit en prod

- `latest` n'est pas "la dernière version", c'est juste le tag par défaut quand on n'en met pas. Il peut pointer sur
  n'importe quoi (une branche de test poussée sans tag par exemple) ;
- il bouge : deux noeuds qui pull à 5 min d'écart peuvent tourner deux versions différentes ;
- pas de rollback possible : "revenir à la version d'avant" n'a pas de sens si tout s'appelle `latest` ;
- on ne sait pas ce qui tourne en lisant le compose ou le manifest k8s ;
- avec `pull_policy: missing` (défaut) un noeud qui a déjà un vieux `latest` en cache ne le met pas à jour.

C'est exactement l'incident du vendredi soir : `latest` réécrit → la prod a pris la nouvelle image au redémarrage.

## Référencer par digest

Le digest (`sha256:...`) est le hash du manifeste : il identifie un contenu de manière unique et ne peut pas bouger.
En prod on référence `tag@digest` : le tag reste lisible pour les humains, mais c'est le digest qui est utilisé.

```yaml
services:
  api:
    image: registry.local:5000/shopapi:1.4.2@sha256:6b0c2e4f...
```

Pour récupérer le digest :

```bash
docker buildx imagetools inspect registry.local:5000/shopapi:1.4.2 --format '{{.Manifest.Digest}}'
# ou via l'API
curl -sI --cacert registry/certs/ca.crt -u dev:dev-pull-2024 \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
  https://registry.local:5000/v2/shopapi/manifests/1.4.2 | grep -i docker-content-digest
```

## Retaguer sans pull

Ajouter `1.4` et `1` sur la `1.4.2` sans télécharger l'image, juste en copiant le manifeste côté registre :

```bash
# crane (reutilise le docker login fait avant)
docker run --rm --network host -v ~/.docker:/docker:ro -e DOCKER_CONFIG=/docker \
  -v $PWD/registry/certs/ca.crt:/ca.crt:ro -e SSL_CERT_FILE=/ca.crt \
  gcr.io/go-containerregistry/crane:v0.20.2 tag registry.local:5000/shopapi:1.4.2 1.4

# ou skopeo
docker run --rm --network host -v $PWD/registry/certs:/certs:ro quay.io/skopeo/stable:v1.16.1 \
  copy --src-cert-dir /certs --dest-cert-dir /certs \
  --src-creds ci:ci-push-2024 --dest-creds ci:ci-push-2024 \
  docker://registry.local:5000/shopapi:1.4.2 docker://registry.local:5000/shopapi:1.4
```

Comme les couches existent déjà dans le dépôt, seul le manifeste est réécrit (quelques Ko). Le digest de `1.4` est
le même que celui de `1.4.2`.
