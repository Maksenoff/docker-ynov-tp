#!/usr/bin/env bash
# verified-run.sh IMAGE [options docker run...]
# lance l'image seulement si la signature cosign est valide, et par digest (pas par tag)
set -euo pipefail

IMAGE="${1:?usage: verified-run.sh IMAGE [options docker run...]}"
shift
COSIGN_PUB=${COSIGN_PUB:-cosign.pub}

if ! out=$(cosign verify --key "$COSIGN_PUB" --insecure-ignore-tlog=true "$IMAGE" 2>/dev/null); then
  echo "signature invalide ou absente pour $IMAGE, refus de lancer" >&2
  exit 1
fi

digest=$(echo "$out" | jq -r '.[0].critical.image."docker-manifest-digest"')
repo="${IMAGE%@*}"
# enleve le tag mais pas le port du registre
case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
echo "signature ok, lancement de $repo@$digest" >&2
exec docker run "$@" "$repo@$digest"
