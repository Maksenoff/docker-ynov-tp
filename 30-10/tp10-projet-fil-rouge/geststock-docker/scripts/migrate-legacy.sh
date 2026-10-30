#!/usr/bin/env bash
# migrate-legacy.sh DUMP.sql DOSSIER_UPLOADS
# importe la base et les photos du serveur legacy dans la stack (a faire une fois, appli arretee)
# cote legacy : mysqldump --single-transaction geststock > dump.sql ; tar des /var/www/html/uploads
# les $(cat /run/secrets/...) sont evalues dans le conteneur db, pas ici
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

DUMP="${1:?usage: migrate-legacy.sh DUMP.sql DOSSIER_UPLOADS}"
UPLOADS="${2:?usage: migrate-legacy.sh DUMP.sql DOSSIER_UPLOADS}"
[ -f "$DUMP" ] || { echo "$DUMP introuvable"; exit 1; }
[ -d "$UPLOADS" ] || { echo "$UPLOADS introuvable"; exit 1; }

read -ra extra <<< "${COMPOSE_ARGS:-}"
COMPOSE=(docker compose "${extra[@]}")
project=$("${COMPOSE[@]}" config --format json | jq -r .name)
mysql_root() {
  "${COMPOSE[@]}" exec -T db sh -c 'exec mariadb -uroot -p"$(cat /run/secrets/db_root_password)" "$@" geststock' sh "$@"
}

echo "-- base"
"${COMPOSE[@]}" up -d --wait db
# appli arretee pendant l'import : personne n'ecrit
"${COMPOSE[@]}" stop app rapport 2>/dev/null || true
mysql_root < "$DUMP"
rows=$(echo "SELECT count(*) FROM items;" | mysql_root -N)
echo "$rows articles importes"

echo "-- photos"
tar -C "$UPLOADS" -cf - . | docker run --rm -i -v "${project}_uploads":/data alpine:3.20 \
  sh -c 'tar -xf - -C /data && chown -R 33:33 /data && find /data -type f | wc -l'

echo "-- verification : chaque photo referencee existe"
missing=0
while read -r photo; do
  [ -f "$UPLOADS/$photo" ] || { echo "manquante : $photo"; missing=$((missing + 1)); }
done < <(echo "SELECT photo FROM items WHERE photo IS NOT NULL;" | mysql_root -N)
echo "$missing photo(s) manquante(s)"

"${COMPOSE[@]}" up -d --wait
echo "migration terminee"
