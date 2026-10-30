#!/usr/bin/env bash
# rolling-update.sh : met a jour l'api un replica a la fois, sans coupure
# VERSION=sha-3f1c9a0 ./deploy/rolling-update.sh
# marche aussi sur un hote distant : DOCKER_CONTEXT=preprod VERSION=... ./deploy/rolling-update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION doit etre defini (ex: sha-3f1c9a0 ou 1.4.2)}"
export VERSION
SERVICE=${SERVICE:-api}
STOP_TIMEOUT=${STOP_TIMEOUT:-15}
COMPOSE=(docker compose -f compose.yml -f compose.prod.yml)

start=$(date +%s)
echo "== deploiement de $SERVICE en $VERSION"
"${COMPOSE[@]}" pull "$SERVICE" worker

# 1er deploiement : rien a remplacer
mapfile -t old < <("${COMPOSE[@]}" ps -q "$SERVICE")
if [ ${#old[@]} -eq 0 ]; then
  "${COMPOSE[@]}" up -d --wait
  echo "== premier deploiement ok ($(( $(date +%s) - start )) s)"
  exit 0
fi

# deja a jour ?
target=$("${COMPOSE[@]}" config --format json | jq -r ".services.\"$SERVICE\".image")
current=$(docker inspect -f '{{.Config.Image}}' "${old[0]}")
echo "actuel : $current -> cible : $target"

# un par un : on ajoute un replica neuf, on attend qu'il soit healthy, puis on retire un ancien
for id in "${old[@]}"; do
  n=$(( $("${COMPOSE[@]}" ps -q "$SERVICE" | wc -l) + 1 ))
  echo "-- +1 replica neuf (total $n)"
  # --no-recreate : les anciens ne sont pas touches, seul le nouveau prend la nouvelle image
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "$SERVICE=$n" --wait "$SERVICE"

  echo "-- arret de l'ancien ${id:0:12} (SIGTERM, ${STOP_TIMEOUT}s max)"
  docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null
  docker rm "$id" >/dev/null
done

echo "-- worker"
"${COMPOSE[@]}" up -d --no-deps --wait worker

"${COMPOSE[@]}" ps "$SERVICE" worker
echo "== $SERVICE en $VERSION sur $("${COMPOSE[@]}" ps -q "$SERVICE" | wc -l) replicas ($(( $(date +%s) - start )) s)"
