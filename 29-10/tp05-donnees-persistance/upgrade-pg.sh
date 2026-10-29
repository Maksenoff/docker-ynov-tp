#!/usr/bin/env bash
# upgrade-pg.sh : PostgreSQL 14 -> 16 par dump/restore, sur un nouveau volume
# retour arriere : docker compose -f compose.yml up -d --wait   (relance PG14 sur l'ancien volume intact)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

OLD=(-f compose.yml)
NEW=(-f compose.yml -f compose.pg16.yml)
TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUP_DIR/upgrade-$TS"
mkdir -p "$DIR"

echo "== 1. etat avant"
docker compose "${OLD[@]}" up -d --wait "$DB_SERVICE"
docker compose "${OLD[@]}" exec -T "$DB_SERVICE" postgres --version
before=$(checksum "${OLD[@]}")
echo "checksum avant : $before"

echo "== 2. dumps"
docker compose "${OLD[@]}" exec -T "$DB_SERVICE" pg_dumpall -U "$DB_USER" > "$DIR/dumpall.sql"
docker compose "${OLD[@]}" exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DIR/$DB_NAME.dump"
ls -lh "$DIR"

echo "== 3. arret de PG14 (volume conserve)"
docker compose "${OLD[@]}" stop "$DB_SERVICE"

echo "== 4. PG16 sur un nouveau volume"
start=$(date +%s)
docker compose "${NEW[@]}" up -d --wait "$DB_SERVICE"
docker compose "${NEW[@]}" exec -T "$DB_SERVICE" postgres --version

echo "== 5. restauration"
docker compose "${NEW[@]}" exec -T "$DB_SERVICE" pg_restore -U "$DB_USER" -d "$DB_NAME" \
  --no-owner --exit-on-error < "$DIR/$DB_NAME.dump"
docker compose "${NEW[@]}" exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -c "ANALYZE;" >/dev/null
echo "indisponibilite : $(( $(date +%s) - start )) s (hors temps du dump)"

echo "== 6. etat apres"
after=$(checksum "${NEW[@]}")
echo "checksum avant : $before"
echo "checksum apres : $after"

if [ "$before" = "$after" ]; then
  echo "== VERDICT : OK, migration sans perte"
  echo "reporter image postgres:16.4-alpine + volume pgdata16 dans compose.yml, garder pgdata quelques jours puis le supprimer"
else
  echo "== VERDICT : KO, les donnees different"
  echo "retour arriere :"
  echo "  docker compose -f compose.yml -f compose.pg16.yml stop db"
  echo "  docker compose -f compose.yml up -d --wait"
  exit 1
fi
