#!/usr/bin/env bash
# smoke test de la stack, en passant par traefik comme un vrai client
set -euo pipefail

BASE=${BASE:-http://localhost}
HOST=${API_HOST:-api.localhost}
COMPOSE=${COMPOSE:-docker compose}

ok()  { echo "  [ok] $*"; }
die() { echo "  [KO] $*"; exit 1; }
api() { curl -fsS -H "Host: $HOST" "$@"; }
sql() { $COMPOSE exec -T db psql -U shop -d shop -tAc "$1"; }

echo "-- /ready"
ready=$(api "$BASE/ready") || die "/ready ne repond pas"
echo "$ready" | jq -e '.status == "ready" and .checks.db == "ok" and .checks.redis == "ok"' >/dev/null \
  || die "/ready : $ready"
ok "db et redis ok"

echo "-- /products et cache redis"
api "$BASE/products" >/dev/null
cache=$(api -o /dev/null -D - "$BASE/products" | grep -i '^x-cache:' | awk '{print $2}' | tr -d '\r')
[ "$cache" = "HIT" ] || die "X-Cache=$cache au 2e appel, attendu HIT"
ok "X-Cache: HIT"

echo "-- commande"
last=$(sql "SELECT coalesce(max(id), 0) FROM orders")
api -X POST -H 'Content-Type: application/json' -d '{"productId":1,"quantity":2}' "$BASE/orders" \
  | jq -e '.status == "pending"' >/dev/null || die "creation de commande"
ok "commande creee (pending)"

status=""
for _ in $(seq 1 15); do
  status=$(sql "SELECT status FROM orders WHERE id > $last ORDER BY id DESC LIMIT 1")
  [ "$status" = "confirmed" ] && break
  sleep 1
done
[ "$status" = "confirmed" ] || die "commande pas confirmee par le worker (status=$status)"
ok "commande confirmee par le worker"

echo "smoke test ok"
