COMPOSE = docker compose
PROD    = docker compose -f compose.yml -f compose.prod.yml

.PHONY: help up down logs ps config tools prod-up prod-down prod-config migrate test clean

help:
	@echo "make up | down | logs | ps | config | tools"
	@echo "make prod-up | prod-down | prod-config"
	@echo "make migrate M=002-add-sku.sql"
	@echo "make test"

# mot de passe aleatoire en hexa (pas de caractere a echapper dans l'url)
# lisible par tous car les secrets compose hors swarm sont de simples bind mounts
secrets/db_password.txt:
	@mkdir -p secrets
	@openssl rand -hex 16 > $@
	@chmod 644 $@
	@echo "mot de passe genere dans $@"

up: secrets/db_password.txt
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

down:
	$(COMPOSE) --profile tools down

logs:
	$(COMPOSE) logs -f --tail 50

ps:
	$(COMPOSE) ps

config:
	$(COMPOSE) config

tools: secrets/db_password.txt
	$(COMPOSE) --profile tools up -d --wait

prod-up: secrets/db_password.txt
	$(PROD) pull
	$(PROD) up -d --wait
	$(PROD) ps

prod-down:
	$(PROD) down

prod-config:
	$(PROD) config

migrate:
	@test -n "$(M)" || (echo "usage : make migrate M=002-add-sku.sql" && exit 1)
	MIGRATION=$(M) $(COMPOSE) run --rm migrate

test:
	./smoke-test.sh

# attention : supprime les volumes (donc la base)
clean:
	$(COMPOSE) --profile tools --profile ops down -v
