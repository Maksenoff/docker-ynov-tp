#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE]
# refuse une image qui ne respecte pas la politique Shop SAS
# si tout est ok et --push : push, signature cosign, attestation SBOM
set -euo pipefail

IMAGE="${1:?usage: release-gate.sh IMAGE [--push REGISTRY_IMAGE]}"
shift
PUSH_TO=""
if [ "${1:-}" = "--push" ]; then
  PUSH_TO="${2:?--push demande une image cible (ex: registry.local:5000/shopapi:1.4.2)}"
  case "${PUSH_TO##*/}" in
    *:*) ;;
    *) echo "il faut un tag explicite dans $PUSH_TO"; exit 2 ;;
  esac
fi

COSIGN_KEY=${COSIGN_KEY:-cosign.key}
CA_CERT=${CA_CERT:-registry/certs/ca.crt}
TRIVY_IMAGE=aquasec/trivy:0.55.2
SYFT_IMAGE=anchore/syft:v1.13.0
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.4.0

# outils en local si installes, sinon en conteneur
trivy() {
  if command -v trivy >/dev/null 2>&1; then command trivy "$@"; return; fi
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" "$@"
}
syft() {
  if command -v syft >/dev/null 2>&1; then command syft "$@"; return; fi
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$SYFT_IMAGE" "$@"
}
cosign() {
  if command -v cosign >/dev/null 2>&1; then command cosign "$@"; return; fi
  local extra=()
  if [ -f "$CA_CERT" ]; then
    extra=(-v "$(realpath "$CA_CERT"):/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt)
  fi
  docker run --rm --network host -v "$PWD:/work" -w /work \
    -v "$HOME/.docker:/docker:ro" -e DOCKER_CONFIG=/docker -e COSIGN_PASSWORD \
    "${extra[@]}" "$COSIGN_IMAGE" "$@"
}

errors=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [KO] $*"; errors=$((errors + 1)); }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE introuvable en local"
  exit 2
fi

echo "== $IMAGE"

echo "-- labels OCI"
for l in version revision source; do
  v=$(docker image inspect "$IMAGE" --format "{{ index .Config.Labels \"org.opencontainers.image.$l\" }}" 2>/dev/null || true)
  case "$v" in
    ""|"<no value>"|unknown) fail "org.opencontainers.image.$l absent" ;;
    *) ok "org.opencontainers.image.$l=$v" ;;
  esac
done

echo "-- utilisateur"
user=$(docker image inspect "$IMAGE" --format '{{.Config.User}}')
case "$user" in
  ""|root|0|root:*|0:*) fail "l'image tourne en root (USER='${user}')" ;;
  *) ok "USER=$user" ;;
esac

echo "-- healthcheck"
hc=$(docker image inspect "$IMAGE" --format '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}')
if [ -z "$hc" ] || [ "$hc" = '["NONE"]' ]; then
  fail "pas de HEALTHCHECK"
else
  ok "HEALTHCHECK $hc"
fi

echo "-- CVE HIGH/CRITICAL corrigeables"
if trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"; then
  ok "aucune CVE HIGH/CRITICAL corrigeable"
else
  fail "CVE HIGH/CRITICAL corrigeables (voir le tableau au dessus)"
fi

echo "-- secrets"
if trivy image --quiet --scanners secret --exit-code 1 "$IMAGE"; then
  ok "aucun secret detecte"
else
  fail "secret detecte dans l'image"
fi

if [ "$errors" -gt 0 ]; then
  echo "== REFUSE : $errors probleme(s)"
  exit 1
fi
echo "== ACCEPTE"

[ -z "$PUSH_TO" ] && exit 0

echo "-- push vers $PUSH_TO"
docker tag "$IMAGE" "$PUSH_TO"
docker push "$PUSH_TO"

# on signe le digest, jamais le tag (un tag peut bouger)
repo="${PUSH_TO%:*}"
ref=$(docker image inspect "$PUSH_TO" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep "^${repo}@" | head -n1)
if [ -z "$ref" ]; then
  echo "impossible de recuperer le digest de $PUSH_TO"
  exit 1
fi
echo "digest : $ref"

echo "-- SBOM"
sbom="sbom-$(echo "$repo" | tr '/:' '__').json"
syft "$IMAGE" -o spdx-json > "$sbom"
echo "$(jq '.packages | length' "$sbom") paquets dans $sbom"

echo "-- signature + attestation"
# registre prive : pas d'upload dans le log de transparence public (rekor)
cosign sign --yes --key "$COSIGN_KEY" --tlog-upload=false "$ref"
cosign attest --yes --key "$COSIGN_KEY" --tlog-upload=false --type spdxjson --predicate "$sbom" "$ref"

echo "== publie et signe : $ref"
