#!/usr/bin/env bash
# simulate-legacy.sh [N] : fabrique ce qu'on recupererait du serveur legacy
#   legacy-sample/dump.sql   (comme un mysqldump de la base geststock)
#   legacy-sample/uploads/   (les photos de /var/www/html/uploads)
set -euo pipefail
cd "$(dirname "$0")/.."

N=${1:-200}
OUT=legacy-sample
rm -rf "$OUT" && mkdir -p "$OUT/uploads"

# png 1x1 valide
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

{
  echo "-- MariaDB dump 10.19  Distrib 10.3.39-MariaDB, for debian-linux-gnu (x86_64)"
  echo "-- Host: localhost    Database: geststock"
  echo "SET NAMES utf8mb4;"
  echo "DROP TABLE IF EXISTS \`items\`;"
  echo "CREATE TABLE \`items\` ("
  echo "  \`id\` int(11) NOT NULL AUTO_INCREMENT,"
  echo "  \`name\` varchar(200) NOT NULL,"
  echo "  \`qty\` int(11) NOT NULL DEFAULT 0,"
  echo "  \`photo\` varchar(100) DEFAULT NULL,"
  echo "  \`created_at\` timestamp NULL DEFAULT current_timestamp(),"
  echo "  PRIMARY KEY (\`id\`)"
  echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
  echo "LOCK TABLES \`items\` WRITE;"
  for i in $(seq 1 "$N"); do
    photo=NULL
    # une photo pour un article sur trois
    if [ $((i % 3)) -eq 0 ]; then
      f="p_legacy$(printf '%05d' "$i").png"
      echo "$PNG" | base64 -d > "$OUT/uploads/$f"
      photo="'$f'"
    fi
    day=$(( (i * 7) % 28 + 1 ))
    echo "INSERT INTO \`items\` VALUES ($i,'Article legacy $i',$(( (i * 13) % 60 )),$photo,'2023-03-$(printf '%02d' $day) 10:00:00');"
  done
  echo "UNLOCK TABLES;"
} > "$OUT/dump.sql"

echo "$N articles dans $OUT/dump.sql, $(find "$OUT/uploads" -type f | wc -l) photos dans $OUT/uploads"
