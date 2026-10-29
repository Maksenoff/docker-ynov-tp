#!/usr/bin/env bash
# backup.sh : dump logique (pg_dump -Fc) + sauvegarde brute du volume, garde les 7 derniers
# RAW=0 pour ne faire que le dump logique (la sauvegarde brute arrete la base quelques secondes)
# pour la stack du TP04 : COMPOSE_FILE=../tp04-compose-entreprise/compose.yml ./backup.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

KEEP=${KEEP:-7}
RAW=${RAW:-1}
VOLUME=${VOLUME:-$(volume_name pgdata)}
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
BACKUP_ABS=$(cd "$BACKUP_DIR" && pwd)

echo "checksum avant : $(checksum)"

echo "-- dump logique"
docker compose exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$BACKUP_DIR/$DB_NAME-$TS.dump"
echo "$BACKUP_DIR/$DB_NAME-$TS.dump ($(du -h "$BACKUP_DIR/$DB_NAME-$TS.dump" | cut -f1))"

if [ "$RAW" = 1 ]; then
  echo "-- sauvegarde brute de $VOLUME"
  # copie des fichiers pendant que postgres ecrit = incoherent, donc on l'arrete
  docker compose stop "$DB_SERVICE"
  docker run --rm -v "$VOLUME":/data:ro -v "$BACKUP_ABS":/backup alpine:3.20 \
    tar czf "/backup/pgdata-$TS.tar.gz" --numeric-owner -C /data .
  docker compose up -d --wait "$DB_SERVICE"
  echo "$BACKUP_DIR/pgdata-$TS.tar.gz ($(du -h "$BACKUP_DIR/pgdata-$TS.tar.gz" | cut -f1))"
fi

echo "-- retention ($KEEP derniers)"
for pattern in "$DB_NAME-*.dump" "pgdata-*.tar.gz"; do
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
    echo "suppression $f"
    rm -f "$f"
  done
done

echo "ok"
