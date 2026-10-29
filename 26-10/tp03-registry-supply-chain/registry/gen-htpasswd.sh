#!/usr/bin/env bash
# cree le fichier htpasswd (bcrypt) avec les comptes ci et dev
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p auth

CI_PASSWORD=${CI_PASSWORD:-ci-push-2024}
DEV_PASSWORD=${DEV_PASSWORD:-dev-pull-2024}

# htpasswd vient de l'image httpd, pas besoin de l'installer
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn ci "$CI_PASSWORD" > auth/htpasswd
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn dev "$DEV_PASSWORD" >> auth/htpasswd

cat auth/htpasswd
