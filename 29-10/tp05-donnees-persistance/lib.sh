# fonctions communes aux scripts backup / restore / upgrade
# shellcheck shell=bash

# pour git bash sous windows (sinon les chemins des -v sont convertis)
export MSYS_NO_PATHCONV=1

DB_SERVICE=${DB_SERVICE:-db}
DB_USER=${DB_USER:-shop}
DB_NAME=${DB_NAME:-shop}
BACKUP_DIR=${BACKUP_DIR:-./backups}

# meme requete que seed.sh, les arguments sont passes a docker compose (ex: -f compose.yml)
# shellcheck disable=SC2120
checksum() {
  docker compose "$@" exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -tA -c \
    "SELECT count(*) || ' ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders;"
}

# nom reel du volume (projet compose + nom du volume)
volume_name() {
  local project
  project=$(docker compose "${@:2}" config --format json | jq -r '.name')
  echo "${project}_$1"
}
