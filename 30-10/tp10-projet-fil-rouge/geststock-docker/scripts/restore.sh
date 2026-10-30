#!/usr/bin/env bash
# restore.sh HORODATAGE   (ex: 20261030-020000, cf ls backups/)
# remplace la base ET les photos par la sauvegarde, appli arretee pendant la restauration
# les $(cat /run/secrets/...) sont evalues dans le conteneur db, pas ici
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

TS="${1:?usage: restore.sh HORODATAGE (ex: 20261030-020000)}"
BACKUP_DIR=${BACKUP_DIR:-./backups}
DB_FILE="$BACKUP_DIR/geststock-$TS.sql.gz"
UP_FILE="$BACKUP_DIR/uploads-$TS.tar.gz"
if [ ! -f "$DB_FILE" ] || [ ! -f "$UP_FILE" ]; then
  echo "sauvegarde $TS incomplete dans $BACKUP_DIR"
  exit 1
fi
BACKUP_ABS=$(cd "$BACKUP_DIR" && pwd)

read -ra extra <<< "${COMPOSE_ARGS:-}"
COMPOSE=(docker compose "${extra[@]}")
project=$("${COMPOSE[@]}" config --format json | jq -r .name)

"${COMPOSE[@]}" stop app rapport 2>/dev/null || true
"${COMPOSE[@]}" up -d --wait db

echo "-- base"
zcat "$DB_FILE" | "${COMPOSE[@]}" exec -T db sh -c 'exec mariadb -uroot -p"$(cat /run/secrets/db_root_password)" geststock'

echo "-- photos"
# create : recree le volume avec les labels compose s'il a ete supprime
"${COMPOSE[@]}" create app >/dev/null
docker run --rm -v "${project}_uploads":/data -v "$BACKUP_ABS":/backup:ro alpine:3.20 \
  sh -c "find /data -mindepth 1 -delete && tar xzf /backup/uploads-$TS.tar.gz --numeric-owner -C /data"

"${COMPOSE[@]}" up -d --wait
n=$(echo "SELECT count(*) FROM items;" | "${COMPOSE[@]}" exec -T db sh -c 'exec mariadb -uroot -p"$(cat /run/secrets/db_root_password)" -N geststock')
echo "restauration $TS ok : $n articles"
