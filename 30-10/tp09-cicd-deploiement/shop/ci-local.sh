#!/usr/bin/env bash
# ci-local.sh [main|tag vX.Y.Z] : rejoue les etapes du pipeline en local, contre le registre du TP03
# signature avec la cle cosign du TP03 (pas de keyless sans OIDC)
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-pr}
REGISTRY=${REGISTRY:-registry.local:5000}
SHA=$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)
export COSIGN_KEY=${COSIGN_KEY:-../../26-10/tp03-registry-supply-chain/cosign.key}
export CA_CERT=${CA_CERT:-../../26-10/tp03-registry-supply-chain/registry/certs/ca.crt}

step() { echo; echo "######## $*"; }

[ -f pip.conf ] || printf '[global]\nindex-url = https://pypi.org/simple\n' > pip.conf
mkdir -p secrets
[ -f secrets/db_password.txt ] || openssl rand -hex 16 > secrets/db_password.txt

step "lint"
for f in apps/*/Dockerfile; do
  echo "hadolint $f"
  docker run --rm -i hadolint/hadolint:v2.12.0 < "$f"
done
docker compose config --quiet
REGISTRY=$REGISTRY VERSION=ci docker compose -f compose.yml -f compose.prod.yml config --quiet
echo "compose ok"

step "tests"
docker buildx build --target test --secret id=pipconf,src=pip.conf -o type=cacheonly apps/shopapi
docker buildx build --target test --secret id=pipconf,src=pip.conf -o type=cacheonly apps/shop-worker

case "$MODE" in
  pr)  tags=() ;;
  main) tags=("sha-$SHA") ;;
  tag)
    v="${2:?usage: ci-local.sh tag v1.4.2}"; v="${v#v}"
    tags=("sha-$SHA" "$v" "${v%.*}")
    ;;
  *) echo "mode inconnu : $MODE"; exit 2 ;;
esac

step "build"
for app in shopapi:apps/shopapi shop-worker:apps/shop-worker; do
  name=${app%%:*}; ctx=${app#*:}
  docker buildx build --target runtime --load \
    --secret id=pipconf,src=pip.conf \
    --build-arg APP_VERSION="${tags[0]:-pr}" --build-arg VERSION="${tags[0]:-pr}" --build-arg GIT_SHA="$SHA" \
    -t "$name:ci" "$ctx"
done

if [ ${#tags[@]} -eq 0 ]; then
  echo; echo "PR : pas de push"
  exit 0
fi

step "gate + push + signature"
for name in shopapi shop-worker; do
  for t in "${tags[@]}"; do
    ../../26-10/tp03-registry-supply-chain/release-gate.sh "$name:ci" --push "$REGISTRY/$name:$t"
  done
done

step "deploiement"
if [ "$MODE" = main ]; then
  REGISTRY=$REGISTRY VERSION="sha-$SHA" ./deploy/rolling-update.sh
else
  # equivalent de l'approbation manuelle de l'environment production
  read -r -p "deployer ${tags[1]} en prod ? [o/N] " ok
  if [ "$ok" = o ]; then
    REGISTRY=$REGISTRY VERSION="${tags[1]}" ./deploy/rolling-update.sh
  fi
fi
