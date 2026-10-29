# Docker avancé - TP Ynov

Mes réponses aux TP du cours Docker (énoncés : [christopheutp/docker_ynov_10_26](https://github.com/christopheutp/docker_ynov_10_26)).

## 26-10

| TP | Sujet | Livrables |
|---|---|---|
| [tp01-optimisation-image](26-10/tp01-optimisation-image) | reprendre une image legacy | `DIAGNOSTIC.md`, `RAPPORT.md`, `shopapi/Dockerfile`, variante distroless |
| [tp02-buildkit-avance](26-10/tp02-buildkit-avance) | secrets, cache, multi-arch, bake | `shop-worker/Dockerfile`, `docker-bake.hcl`, `RAPPORT.md` |
| [tp03-registry-supply-chain](26-10/tp03-registry-supply-chain) | registre privé, SBOM, scan, signature | `registry/`, `release-gate.sh`, `retention.sh`, `TAGGING.md`, `RAPPORT.md` |

## 29-10

| TP | Sujet | Livrables |
|---|---|---|
| [tp04-compose-entreprise](29-10/tp04-compose-entreprise) | stack compose dev / prod | `compose*.yml`, `Makefile`, `smoke-test.sh`, `RAPPORT.md` |
| [tp05-donnees-persistance](29-10/tp05-donnees-persistance) | volumes, backup, upgrade PG 14 -> 16 | `backup.sh`, `restore.sh`, `upgrade-pg.sh`, `REPONSES.md`, `TRANSCRIPT.md` |
| [tp06-reseau-debug](29-10/tp06-reseau-debug) | incident réseau en préprod | `compose.yml`, `nginx/default.conf`, `INCIDENT.md` |
| [tp07-observabilite](29-10/tp07-observabilite) | prometheus, loki, grafana, alertes | `compose.observability.yml`, configs, dashboard, `REPONSES.md` |

Les TP s'enchaînent : l'image du TP01 et celle du TP02 sont reprises dans `29-10/tp04-compose-entreprise/apps/`,
la stack du TP04 sert aux TP05, 06 et 07.
