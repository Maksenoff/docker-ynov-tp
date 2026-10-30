#!/usr/bin/env bash
# measure-downtime.sh [DUREE_S] : ~100 req/s sur /health pendant DUREE_S secondes, compte les echecs
# a lancer dans un terminal pendant qu'on deploie dans un autre
set -uo pipefail

DURATION=${1:-60}
RATE=${RATE:-100}
URL=${URL:-http://localhost/health}
API_HOST=${API_HOST:-api.localhost}
out=$(mktemp)
trap 'rm -f "$out"' EXIT

echo "$RATE req/s sur $URL pendant ${DURATION}s"
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  t=$SECONDS
  for _ in $(seq "$RATE"); do
    { code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H "Host: $API_HOST" "$URL"); echo "$t $code" >> "$out"; } &
  done
  wait
  # on complete la seconde si les requetes ont ete plus rapides
  while [ $SECONDS -eq "$t" ]; do sleep 0.05; done
done

total=$(wc -l < "$out")
fails=$(awk '$2 != 200' "$out" | wc -l)
echo
echo "requetes : $total"
echo "echecs   : $fails"
if [ "$fails" -gt 0 ]; then
  echo "detail (seconde, code, nombre) :"
  awk '$2 != 200 {print $1 - s, $2}' s="$(head -n1 "$out" | cut -d' ' -f1)" "$out" | sort -n | uniq -c | awk '{print "  t+" $2 "s  code " $3 "  x" $1}'
fi
[ "$fails" -eq 0 ]
