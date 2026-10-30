#!/usr/bin/env bash
# rolling-update.sh : met a jour l'appli un replica a la fois (cf TP09), puis le conteneur du rapport
# VERSION=1.0.1 ./deploy/rolling-update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION doit etre defini}"
export VERSION
STOP_TIMEOUT=${STOP_TIMEOUT:-15}
COMPOSE=(docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml)

start=$(date +%s)
"${COMPOSE[@]}" pull app rapport

mapfile -t old < <("${COMPOSE[@]}" ps -q app)
if [ ${#old[@]} -eq 0 ]; then
  "${COMPOSE[@]}" up -d --wait
  echo "premier deploiement ok"
  exit 0
fi

for id in "${old[@]}"; do
  n=$(( $("${COMPOSE[@]}" ps -q app | wc -l) + 1 ))
  echo "-- +1 replica neuf (total $n)"
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "app=$n" --wait app
  # SIGWINCH (STOPSIGNAL de l'image) : apache finit les requetes en cours puis s'arrete
  echo "-- arret de l'ancien ${id:0:12}"
  docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null
  docker rm "$id" >/dev/null
done

# le rapport n'a pas de trafic entrant, une simple recreation suffit
"${COMPOSE[@]}" up -d --no-deps --wait rapport
"${COMPOSE[@]}" ps app rapport
echo "== geststock $VERSION deploye en $(( $(date +%s) - start )) s"
