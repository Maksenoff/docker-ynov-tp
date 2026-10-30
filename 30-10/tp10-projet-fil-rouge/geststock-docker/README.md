# geststock-docker

GestStock (inventaire PHP, ex serveur Debian 10 / PHP 7.3 installé à la main) livré en stack conteneurisée.
L'exploitation au quotidien est dans [RUNBOOK.md](RUNBOOK.md).

```bash
make up              # dev : http://geststock.localhost  mails : http://mail.localhost  traefik : :8080
make legacy-sample && make migrate-legacy
make test
```

## Livrables

| # | Livrable | Où |
|---|---|---|
| 1 | Dockerfile multi-stage (`test` = `php -l` sur tout le code), `php:8.3-apache`, non-root (`www-data`, Apache sur 8080), `HEALTHCHECK` sur `?health`, labels OCI, `php.ini-production` + `display_errors=Off` + upload 20M/25M, `.dockerignore` | [Dockerfile](Dockerfile), [docker/](docker/) |
| 2 | Logs : `app_log` écrit une ligne JSON sur `php://stderr`, Apache logue sur stdout/stderr | [geststock/lib/db.php](geststock/lib/db.php), [docker/apache/geststock.conf](docker/apache/geststock.conf) |
| 3 | Config par `getenv()` avec valeurs par défaut, mot de passe via `DB_PASS_FILE` | [geststock/lib/config.php](geststock/lib/config.php) |
| 4 | compose base + dev + prod : MariaDB 11.4.3 + volume + `schema.sql`, volume `uploads` partagé, réseaux `front` / `back` (internal) / `socket` (internal) / `mail`, healthchecks, `depends_on` conditionnels, Traefik, limites, logs rotatifs | [compose.yml](compose.yml), [compose.override.yml](compose.override.yml), [compose.prod.yml](compose.prod.yml) |
| 5 | Cron : service `rapport` (même image, `supercronic`), mails vers Mailpit en dev (`SMTP_HOST`), `make rapport` pour le lancer à la demande | [docker/crontab](docker/crontab), service `rapport` |
| 6 | Données : `migrate-legacy.sh` (dump + photos), `backup.sh` / `restore.sh`, procédure dans le runbook | [scripts/](scripts/) |
| 7 | Observabilité : rejoint la stack du TP07 (voir plus bas) | |
| 8 | Sécurité : `compose.hardened.yml`, `audit.sh` sans écart (hors socket-proxy), image qui passe `release-gate.sh` | [compose.hardened.yml](compose.hardened.yml), [scripts/audit.sh](scripts/audit.sh), [scripts/release-gate.sh](scripts/release-gate.sh) |
| 9 | CI/CD : hadolint → `php -l` → stack démarrée + migration + smoke test + audit → gate → push GHCR multi-arch + signature → rolling update | [.github/workflows/ci.yml](.github/workflows/ci.yml), [deploy/rolling-update.sh](deploy/rolling-update.sh) |
| 10 | Runbook | [RUNBOOK.md](RUNBOOK.md) |

## Modifications du code (à la marge)

- `lib/config.php` : plus aucune valeur en dur, `getenv()` avec valeurs par défaut, `DB_PASS` lu depuis le fichier
  `DB_PASS_FILE` (secret docker). Le mot de passe `GestStock2017!` qui était dans git a disparu (il faudra le
  changer côté legacy aussi : il est dans l'historique git).
- `lib/db.php` : `app_log` écrit du JSON sur stderr au lieu de `/var/log/geststock/app.log`.
- rien d'autre : `index.php` et `rapport.php` sont intacts. `mail()` marche grâce à `sendmail_path` → `msmtp` vers
  `SMTP_HOST` (remplace le postfix local du serveur).

Passage PHP 7.3 → 8.3 : le code est simple (PDO, pas d'extension retirée, pas de fonctions supprimées), `php -l`
passe en 8.3 dans l'étape `test`. L'extension `gd` installée sur le legacy n'est utilisée nulle part : pas reprise.

## Choix

### Apache intégré (`php:8.3-apache`) plutôt que nginx + php-fpm

- un seul conteneur à construire, scaler, superviser et durcir ; un seul process à observer ;
- l'appli est minuscule (une page, des uploads) : le gain de perf de fpm ne se verra pas ;
- c'est le même modèle que le serveur legacy (mod_php + alias `/uploads`), migration plus simple à valider ;
- avec nginx + fpm il faudrait partager le code et les uploads entre deux conteneurs (volume ou image commune),
  plus de config, plus de points de panne.

nginx + fpm vaudrait le coup avec beaucoup de fichiers statiques ou si on voulait scaler PHP indépendamment.

### Cron : supercronic dans un conteneur dédié, même image

- **simplicité** : même image que l'appli → même code, même config, même secret ; rien à installer en plus sur
  l'hôte, la crontab est versionnée dans le repo ;
- **observabilité** : supercronic écrit la sortie des jobs sur stdout (→ Loki) avec le code retour, et expose des
  métriques Prometheus (utilisées pour son healthcheck) ;
- **sécurité** : tourne en `www-data`, pas besoin du vrai `cron` (qui veut être root et ne passe pas les variables
  d'environnement aux jobs), pas de socket docker (contrairement à ofelia qui pilote `docker exec` par labels) ;
- **testable à la demande** : `make rapport` = `docker compose run --rm rapport php bin/rapport.php` ;
- vs cron hôte : la conf cron serait hors du repo et dépendrait du serveur.

Le conteneur `rapport` n'a pas de réplica : sinon le rapport partirait deux fois.

### Volume uploads en prod

Volume nommé local pour l'instant : une seule machine en prod comme avant, sauvegardé par `backup.sh`
avec la base. Les deux réplicas de l'appli sont sur le même hôte donc partagent le volume sans problème.
Si on passe à plusieurs hôtes : NFS (`driver_opts: type: nfs`) en premier car aucun changement de code ; S3 (MinIO
ou bucket) plus robuste et scalable mais demande de modifier l'upload et l'affichage des photos (sortie du "à la marge").

## Observabilité (TP07)

Rien à modifier dans GestStock :

- **logs** : Promtail (TP07) découvre tous les conteneurs via la socket. Les logs arrivent avec `project="geststock"`,
  `service="app"` / `"rapport"` / `"db"`, le champ `level` des lignes JSON de `app_log` est extrait :
  `{project="geststock", service="app"} | json | level="ERROR"` ;
- **métriques** : cAdvisor voit tous les conteneurs de l'hôte → CPU / mémoire / réseau de `geststock-app-*` dans le
  dashboard (en changeant le filtre `name=~"shop-.*"` en `name=~"(shop|geststock)-.*"`) ;
- les alertes conteneur du TP07 (redémarrage, OOM, mémoire > 90 %) s'appliquent aussi.

Bonus exporter MySQL : `prom/mysqld-exporter:v0.15.1` sur le réseau `back`, avec un utilisateur dédié
(`GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%'`, mot de passe en secret), et Prometheus qui
rejoint `geststock_back` en `external` pour le scraper sur `:9104`.

## Points à vérifier

- `audit.sh` sans écart sur `app`, `rapport`, `db`, `traefik` avec `compose.hardened.yml`. Seul `socket-proxy`
  reste en écart (root + socket, voulu : cf TP08).
- `release-gate.sh` : labels OCI, `USER www-data`, `HEALTHCHECK`, pas de CVE HIGH/CRITICAL corrigeable, pas de secret.
  L'image de base Debian peut remonter des CVE corrigées entre deux builds : il suffit de rebuilder (le gate le dira).
