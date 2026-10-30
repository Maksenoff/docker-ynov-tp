#!/usr/bin/env bash
# smoke-test.sh : sante, ajout d'un article avec photo, photo servie, upload php refuse, rapport
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=${BASE:-http://localhost}
HOST=${APP_HOST:-geststock.localhost}
read -ra extra <<< "${COMPOSE_ARGS:-}"
COMPOSE=(docker compose "${extra[@]}")

ok()  { echo "  [ok] $*"; }
die() { echo "  [KO] $*"; exit 1; }
web() { curl -fsS -H "Host: $HOST" "$@"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$tmp/test.png"
echo '<?php echo "pwned";' > "$tmp/shell.php"

echo "-- sante"
[ "$(web "$BASE/?health")" = "OK" ] || die "?health"
ok "?health = OK"

echo "-- ajout d'un article avec photo"
name="smoke-$(date +%s)"
web -o /dev/null -F "name=$name" -F qty=3 -F "photo=@$tmp/test.png" "$BASE/"
page=$(web "$BASE/")
echo "$page" | grep -q "$name" || die "article absent de la liste"
ok "article $name visible"

photo=$(echo "$page" | grep -A3 "$name" | grep -o '/uploads/p_[^"]*' | head -n1)
[ -n "$photo" ] || die "pas de photo dans la page"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE$photo")
[ "$code" = 200 ] || die "photo $photo -> $code"
ok "photo servie ($photo)"

echo "-- un .php dans les uploads n'est jamais execute"
web -o /dev/null -F "name=$name-php" -F qty=1 -F "photo=@$tmp/shell.php" "$BASE/"
if web "$BASE/" | grep -q "uploads/p_[^\"]*\.php"; then die "upload .php accepte"; fi
ok "extension .php refusee"

echo "-- rapport a la demande"
out=$("${COMPOSE[@]}" run --rm -T rapport php bin/rapport.php)
echo "$out" | grep -q "Articles:" || die "rapport : $out"
ok "rapport genere"
if curl -fsS -H "Host: mail.localhost" "$BASE/api/v1/messages" 2>/dev/null | grep -q "Rapport stock"; then
  ok "mail recu dans mailpit"
fi

echo "smoke test ok"
