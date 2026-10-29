#!/usr/bin/env bash
# restore.sh FICHIER
#   .dump   -> pg_restore dans la base (la base doit exister, elle est recreee par l'image si le volume est vide)
#   .tar.gz -> remplace tout le contenu du volume (base arretee)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

FILE="${1:?usage: restore.sh FICHIER.dump|FICHIER.tar.gz}"
[ -f "$FILE" ] || { echo "$FILE introuvable"; exit 1; }
VOLUME=${VOLUME:-$(volume_name pgdata)}

case "$FILE" in
  *.dump)
    docker compose up -d --wait "$DB_SERVICE"
    docker compose exec -T "$DB_SERVICE" pg_restore -U "$DB_USER" -d "$DB_NAME" \
      --clean --if-exists --no-owner --exit-on-error < "$FILE"
    ;;
  *.tar.gz)
    FILE_ABS=$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")
    docker compose stop "$DB_SERVICE" 2>/dev/null || true
    # cree le volume (avec les labels compose) s'il a ete supprime
    docker compose create "$DB_SERVICE"
    docker run --rm -v "$VOLUME":/data -v "$FILE_ABS":/backup.tar.gz:ro alpine:3.20 \
      sh -c 'find /data -mindepth 1 -delete && tar xzf /backup.tar.gz --numeric-owner -C /data'
    docker compose up -d --wait "$DB_SERVICE"
    ;;
  *)
    echo "format inconnu : $FILE"
    exit 1
    ;;
esac

echo "checksum apres restauration : $(checksum)"
