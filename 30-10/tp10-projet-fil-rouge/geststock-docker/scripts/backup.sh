#!/usr/bin/env bash
# backup.sh : dump de la base (a chaud, coherent grace a --single-transaction) + archive des photos
# garde les KEEP derniers (7 par defaut)
# les $(cat /run/secrets/...) sont evalues dans le conteneur db, pas ici
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

KEEP=${KEEP:-7}
BACKUP_DIR=${BACKUP_DIR:-./backups}
read -ra extra <<< "${COMPOSE_ARGS:-}"
COMPOSE=(docker compose "${extra[@]}")
project=$("${COMPOSE[@]}" config --format json | jq -r .name)
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
BACKUP_ABS=$(cd "$BACKUP_DIR" && pwd)

echo "-- base"
"${COMPOSE[@]}" exec -T db sh -c \
  'exec mariadb-dump -uroot -p"$(cat /run/secrets/db_root_password)" --single-transaction --routines --triggers geststock' \
  | gzip > "$BACKUP_DIR/geststock-$TS.sql.gz"

echo "-- photos"
docker run --rm -v "${project}_uploads":/data:ro -v "$BACKUP_ABS":/backup alpine:3.20 \
  tar czf "/backup/uploads-$TS.tar.gz" --numeric-owner -C /data .

ls -lh "$BACKUP_DIR"/*"$TS"*

# un dump vide ou tronque = pas de sauvegarde
zcat "$BACKUP_DIR/geststock-$TS.sql.gz" | tail -n1 | grep -q 'Dump completed' \
  || { echo "dump incomplet !"; exit 1; }

for pattern in 'geststock-*.sql.gz' 'uploads-*.tar.gz'; do
  # glob voulu
  # shellcheck disable=SC2012,SC2086
  ls -1t "$BACKUP_DIR"/$pattern | tail -n +$((KEEP + 1)) | xargs -r rm -v
done
echo "sauvegarde $TS ok"
