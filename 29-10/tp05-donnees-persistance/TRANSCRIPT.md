# Transcript

## Sauvegarde / destruction / restauration

```
$ docker compose up -d --wait
 ✔ Network shopdata_default  Created
 ✔ Volume "shopdata_pgdata"  Created
 ✔ Container shopdata-db-1   Healthy

$ ./seed.sh
CREATE TABLE
CREATE TABLE
INSERT 0 500
INSERT 0 100000
 orders |             checksum
--------+----------------------------------
 100000 | 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
(1 row)

$ ./backup.sh
checksum avant : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
-- dump logique
./backups/shop-20261029-103512.dump (1.1M)
-- sauvegarde brute de shopdata_pgdata
 ✔ Container shopdata-db-1  Stopped
 ✔ Container shopdata-db-1  Healthy
./backups/pgdata-20261029-103512.tar.gz (9.6M)
-- retention (7 derniers)
ok

$ docker compose down -v
 ✔ Container shopdata-db-1   Removed
 ✔ Volume shopdata_pgdata    Removed
 ✔ Network shopdata_default  Removed

$ docker volume ls | grep shopdata
$

$ docker compose up -d --wait
 ✔ Network shopdata_default  Created
 ✔ Volume "shopdata_pgdata"  Created
 ✔ Container shopdata-db-1   Healthy

$ docker compose exec -T db psql -U shop -d shop -c 'SELECT count(*) FROM orders'
ERROR:  relation "orders" does not exist

$ ./restore.sh backups/shop-20261029-103512.dump
 ✔ Container shopdata-db-1  Healthy
checksum apres restauration : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
```

Même checksum : la restauration logique est bonne.

Même chose avec l'archive brute :

```
$ docker compose down -v
$ ./restore.sh backups/pgdata-20261029-103512.tar.gz
 ✔ Volume "shopdata_pgdata"  Created
 ✔ Container shopdata-db-1   Created
 ✔ Container shopdata-db-1   Healthy
checksum apres restauration : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
```

## Montée de version 14 → 16

```
$ ./upgrade-pg.sh
== 1. etat avant
 ✔ Container shopdata-db-1  Healthy
postgres (PostgreSQL) 14.13
checksum avant : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
== 2. dumps
total 12M
-rw-r--r-- 1 dev dev 9.8M Oct 29 10:41 dumpall.sql
-rw-r--r-- 1 dev dev 1.1M Oct 29 10:41 shop.dump
== 3. arret de PG14 (volume conserve)
 ✔ Container shopdata-db-1  Stopped
== 4. PG16 sur un nouveau volume
 ✔ Volume "shopdata_pgdata16"  Created
 ✔ Container shopdata-db-1     Recreated
 ✔ Container shopdata-db-1     Healthy
postgres (PostgreSQL) 16.4
== 5. restauration
indisponibilite : 9 s (hors temps du dump)
== 6. etat apres
checksum avant : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
checksum apres : 100000 8c1f4b0e9d7a2c35e61f0a4b7d93c2e8
== VERDICT : OK, migration sans perte
reporter image postgres:16.4-alpine + volume pgdata16 dans compose.yml, garder pgdata quelques jours puis le supprimer

$ docker volume ls | grep shopdata
local     shopdata_pgdata
local     shopdata_pgdata16
```

Test du retour arrière :

```
$ docker compose -f compose.yml -f compose.pg16.yml stop db
$ docker compose -f compose.yml up -d --wait
 ✔ Container shopdata-db-1  Recreated
 ✔ Container shopdata-db-1  Healthy
$ docker compose exec -T db postgres --version
postgres (PostgreSQL) 14.13
$ docker compose exec -T db psql -U shop -d shop -tAc "SELECT count(*) FROM orders"
100000
```
