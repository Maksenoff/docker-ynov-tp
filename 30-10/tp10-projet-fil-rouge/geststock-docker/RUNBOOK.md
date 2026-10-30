# Runbook GestStock

Prod : serveur `/opt/geststock` (repo cloné), commandes lancées depuis ce dossier.
Toujours avec les 3 fichiers en prod :

```bash
alias gs='docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml'
```

## Démarrer

Première installation :

```bash
git clone <repo> /opt/geststock && cd /opt/geststock
cp .env.example .env                    # REGISTRY, VERSION, SMTP_HOST...
make secrets/db_password.txt secrets/db_root_password.txt
docker login ghcr.io                    # token read:packages
gs up -d --wait
gs ps                                   # tout doit etre (healthy)
curl -H 'Host: geststock.localhost' localhost/?health    # OK
```

Arrêt : `gs down` (**jamais** `down -v` : ça supprime la base et les photos).

## Mettre à jour

Normalement fait par la CI (push sur `main` → préprod, tag `v*` → prod après approbation). À la main :

```bash
VERSION=1.0.1 ./deploy/rolling-update.sh
```

Un réplica à la fois, zéro interruption. Vérifier ensuite `gs ps` et les logs (`gs logs --since 5m app`).
Si le schéma change : migration **compatible avec l'ancienne version** (ajout de colonne, pas de renommage) lancée
avant le déploiement.

## Revenir en arrière

```bash
VERSION=<version precedente> ./deploy/rolling-update.sh
```

Les versions précédentes sont dans le registre (tags immuables) et en général encore sur le serveur
(`docker images | grep geststock`). Ça prend ~20 s. Si la base a été modifiée de façon incompatible : restaurer la
sauvegarde d'avant la mise à jour (voir plus bas), avec perte des écritures entre les deux.

## Sauvegarder / restaurer

Sauvegarde (base à chaud + photos), à mettre dans le cron de l'hôte, résultat à copier hors du serveur :

```bash
0 2 * * * cd /opt/geststock && COMPOSE_ARGS="-f compose.yml -f compose.prod.yml -f compose.hardened.yml" ./scripts/backup.sh >> /var/log/geststock-backup.log 2>&1
```

Garde les 7 dernières dans `backups/`. Le script échoue si le dump n'est pas complet (dernière ligne
`-- Dump completed`).

Restauration :

```bash
ls backups/                                         # choisir l'horodatage
COMPOSE_ARGS="-f compose.yml -f compose.prod.yml -f compose.hardened.yml" ./scripts/restore.sh 20261030-020000
```

Coupe l'appli pendant la restauration (base + photos remplacées ensemble pour rester cohérents), puis relance tout.
**Tester une restauration chaque mois** sur la préprod : une sauvegarde jamais restaurée n'existe pas.

Migration initiale depuis le serveur legacy (une seule fois) :

```bash
# sur le legacy
mysqldump --single-transaction geststock > dump.sql
tar czf uploads.tgz -C /var/www/html/uploads .
# sur le nouveau serveur
mkdir legacy && tar xzf uploads.tgz -C legacy && ./scripts/migrate-legacy.sh dump.sql legacy
```

Le script arrête l'appli, importe, copie les photos dans le volume (propriétaire www-data) et vérifie que chaque
photo référencée en base existe.

## Diagnostiquer

| Symptôme | Où regarder |
|---|---|
| page d'erreur / 502 | `gs ps` (healthy ?), `gs logs --tail 100 app traefik` |
| "DB KO" sur `?health` | `gs logs db`, `gs exec db healthcheck.sh --connect`, secret lisible ? (`gs exec app cat /run/secrets/db_password`) |
| erreurs PHP | `gs logs app` (`display_errors` est Off : les erreurs vont dans les logs, jamais à l'écran) |
| rapport pas reçu | `gs logs rapport` (sortie du job + code retour), test direct : `gs run --rm rapport php bin/rapport.php` |
| upload qui échoue | > 20 Mo ? `/tmp` plein (tmpfs 64 Mo) ? droits du volume (`gs exec app ls -ld /var/www/uploads` → www-data) |
| lenteur | dashboard Grafana du TP07 (CPU/mémoire des conteneurs `geststock-*`), `docker stats` |

Logs centralisés : Grafana → Explore → Loki : `{project="geststock"}`, erreurs applicatives :
`{project="geststock"} | json | level="ERROR"`. Métriques : dashboard "Shop SAS" (cAdvisor).
Réseau : `docker run --rm -it --network container:geststock-app-1 nicolaka/netshoot` (cf TP06).

## Rotation des secrets

Mot de passe applicatif (`db_password`) :

```bash
NEW=$(openssl rand -hex 16)
gs exec db sh -c "mariadb -uroot -p\"\$(cat /run/secrets/db_root_password)\" -e \"ALTER USER 'geststock'@'%' IDENTIFIED BY '$NEW'\""
echo "$NEW" > secrets/db_password.txt
VERSION=$(grep ^VERSION .env | cut -d= -f2) ./deploy/rolling-update.sh     # les conteneurs relisent le fichier
```

Pendant les quelques secondes entre l'`ALTER USER` et le redémarrage, les anciens réplicas gardent leur connexion
déjà ouverte mais une nouvelle connexion échouerait : faire la rotation en heure creuse (ou créer un 2e utilisateur,
basculer, supprimer l'ancien pour une rotation sans coupure).

Root (`db_root_password`) : même principe avec `ALTER USER 'root'@'%'` et `'root'@'localhost'`, puis
`gs up -d db` (seuls les scripts de sauvegarde l'utilisent).
