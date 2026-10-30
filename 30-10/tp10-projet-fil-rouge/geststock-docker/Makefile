COMPOSE  = docker compose
PROD     = docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml
HARDENED = docker compose -f compose.yml -f compose.override.yml -f compose.hardened.yml

.PHONY: help up down logs hardened prod-up prod-down rapport test audit gate backup restore legacy-sample migrate-legacy clean

help:
	@echo "dev       : make up | down | logs | rapport | test"
	@echo "durci     : make hardened | audit"
	@echo "prod      : make prod-up | prod-down | gate IMAGE=..."
	@echo "donnees   : make backup | restore TS=... | legacy-sample | migrate-legacy"

# mots de passe aleatoires hors git, lisibles par les uid des conteneurs (secrets compose = bind mounts)
secrets/db_password.txt secrets/db_root_password.txt:
	@mkdir -p secrets
	@openssl rand -hex 16 > $@
	@chmod 644 $@
	@echo "genere : $@"

SECRETS = secrets/db_password.txt secrets/db_root_password.txt

up: $(SECRETS)
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f --tail 50

hardened: $(SECRETS)
	$(HARDENED) up -d --build --wait
	$(HARDENED) ps

prod-up: $(SECRETS)
	$(PROD) pull
	$(PROD) up -d --wait

prod-down:
	$(PROD) down

# le rapport de 6h, tout de suite
rapport:
	$(COMPOSE) run --rm rapport php bin/rapport.php

test:
	./scripts/smoke-test.sh

audit:
	./scripts/audit.sh $$($(COMPOSE) ps --format '{{.Name}}' | grep -v socket-proxy)

gate:
	@test -n "$(IMAGE)" || (echo "usage : make gate IMAGE=localhost:5000/geststock:dev" && exit 1)
	./scripts/release-gate.sh $(IMAGE)

backup:
	./scripts/backup.sh

restore:
	@test -n "$(TS)" || (echo "usage : make restore TS=20261030-020000" && ls backups/ && exit 1)
	./scripts/restore.sh $(TS)

legacy-sample:
	./scripts/simulate-legacy.sh 200

migrate-legacy: $(SECRETS)
	./scripts/migrate-legacy.sh legacy-sample/dump.sql legacy-sample/uploads

# supprime aussi les volumes (base + photos)
clean:
	$(COMPOSE) down -v
