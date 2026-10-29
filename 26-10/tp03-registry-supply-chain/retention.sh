#!/usr/bin/env bash
# retention.sh REPO [N]
# garde les N tags hors semver les plus recents, les tags semver (1.4.2, v2.0.0) ne sont jamais supprimes
# DRY_RUN=0 pour supprimer pour de vrai
set -euo pipefail

REPO="${1:?usage: retention.sh REPO [N]}"
KEEP="${2:-5}"
REGISTRY=${REGISTRY:-https://registry.local:5000}
REG_USER=${REG_USER:-ci}
REG_PASS=${REG_PASS:?REG_PASS doit etre defini}
CA_CERT=${CA_CERT:-registry/certs/ca.crt}
DRY_RUN=${DRY_RUN:-1}

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
api() { curl -fsS --cacert "$CA_CERT" -u "$REG_USER:$REG_PASS" "$@"; }

digest_of() {
  api -I -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1" \
    | grep -i '^docker-content-digest:' | awk '{print $2}' | tr -d '\r'
}

created_of() {
  local m
  m=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1")
  # image multi-arch : on prend le 1er manifeste de l'index
  if echo "$m" | jq -e '.manifests' >/dev/null; then
    m=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$(echo "$m" | jq -r '.manifests[0].digest')")
  fi
  api "$REGISTRY/v2/$REPO/blobs/$(echo "$m" | jq -r '.config.digest')" | jq -r '.created // "1970-01-01T00:00:00Z"'
}

semver='^v?[0-9]+\.[0-9]+\.[0-9]+$'
tags=$(api "$REGISTRY/v2/$REPO/tags/list" | jq -r '.tags[]?')

keep_digests=""
candidates=""
for t in $tags; do
  # signatures / attestations cosign : on n'y touche pas
  case "$t" in sha256-*) continue ;; esac
  if [[ "$t" =~ $semver ]]; then
    keep_digests="$keep_digests $(digest_of "$t")"
  else
    candidates="$candidates$(created_of "$t") $t"$'\n'
  fi
done

to_delete=$(printf '%s' "$candidates" | grep -v '^$' | sort -r | tail -n +$((KEEP + 1)) | awk '{print $2}' || true)

if [ -z "$to_delete" ]; then
  echo "rien a supprimer"
  exit 0
fi

for t in $to_delete; do
  d=$(digest_of "$t")
  # supprimer un manifeste supprime TOUS les tags qui pointent dessus
  if [[ " $keep_digests " == *" $d "* ]]; then
    echo "skip $t : meme digest qu'un tag semver ($d)"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] supprimerait $REPO:$t ($d)"
  else
    api -X DELETE "$REGISTRY/v2/$REPO/manifests/$d"
    echo "supprime $REPO:$t ($d)"
  fi
done

[ "$DRY_RUN" = 1 ] || echo "pensez au garbage-collect : docker compose -f registry/compose.yml exec registry registry garbage-collect /etc/docker/registry/config.yml"
