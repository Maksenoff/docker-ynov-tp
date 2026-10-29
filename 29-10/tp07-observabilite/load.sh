#!/usr/bin/env bash
# load.sh [N] : envoie N requetes a l'api via traefik
# melange : surtout /products, des commandes (dont des grosses -> rejected), des 404 et des 400
set -euo pipefail

N=${1:-1000}
PARALLEL=${PARALLEL:-10}
export BASE=${BASE:-http://localhost}
export API_HOST=${API_HOST:-api.localhost}

hit() {
  local i=$1
  case $((i % 10)) in
    0|1)
      curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $API_HOST" -H 'Content-Type: application/json' \
        -X POST -d "{\"productId\":$((i % 5 + 1)),\"quantity\":$((i % 150))}" "$BASE/orders" ;;
    2)
      curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $API_HOST" "$BASE/nexistepas" ;;
    *)
      curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $API_HOST" "$BASE/products" ;;
  esac
}
export -f hit

echo "$N requetes, $PARALLEL en parallele"
seq 1 "$N" | xargs -P "$PARALLEL" -I{} bash -c 'hit {}' | sort | uniq -c
