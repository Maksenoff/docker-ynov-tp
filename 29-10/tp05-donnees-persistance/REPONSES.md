# TP05 - Données : persistance, sauvegarde, montée de version

Fichiers : [backup.sh](backup.sh), [restore.sh](restore.sh), [upgrade-pg.sh](upgrade-pg.sh), [lib.sh](lib.sh)
(fonctions communes), [compose.pg16.yml](compose.pg16.yml), [compose.backup.yml](compose.backup.yml).
Le terminal de la restauration et de la montée de version est dans [TRANSCRIPT.md](TRANSCRIPT.md).

Tous les scripts passent par des conteneurs (`docker compose exec`, `docker run alpine`), pas besoin de `psql` sur
l'hôte. Par défaut ils travaillent sur la stack de ce dossier (`shopdata`), pour celle du TP04 :
`COMPOSE_FILE=../tp04-compose-entreprise/compose.yml ./backup.sh`.

## 1. Anatomie du stockage

Avec la stack du TP04 lancée :

```
$ docker inspect $(docker compose ps -q db) --format '{{json .Mounts}}' | jq
[
  {
    "Type": "volume",
    "Name": "shop_pgdata",
    "Source": "/var/lib/docker/volumes/shop_pgdata/_data",
    "Destination": "/var/lib/postgresql/data",
    "Driver": "local",
    "Mode": "z",
    "RW": true,
    "Propagation": ""
  },
  {
    "Type": "bind",
    "Source": "/home/dev/docker-ynov-tp/29-10/tp04-compose-entreprise/db/init.sql",
    "Destination": "/docker-entrypoint-initdb.d/01-init.sql",
    "Mode": "ro",
    "RW": false,
    "Propagation": "rprivate"
  },
  {
    "Type": "bind",
    "Source": "/home/dev/docker-ynov-tp/29-10/tp04-compose-entreprise/secrets/db_password.txt",
    "Destination": "/run/secrets/db_password",
    "Mode": "ro",
    "RW": false,
    "Propagation": "rprivate"
  }
]

$ docker volume inspect shop_pgdata
[
  {
    "CreatedAt": "2026-10-29T10:02:11Z",
    "Driver": "local",
    "Labels": {
      "com.docker.compose.project": "shop",
      "com.docker.compose.version": "2.29.2",
      "com.docker.compose.volume": "pgdata"
    },
    "Mountpoint": "/var/lib/docker/volumes/shop_pgdata/_data",
    "Name": "shop_pgdata",
    "Options": null,
    "Scope": "local"
  }
]
```

On voit au passage que le secret compose n'est qu'un bind mount en lecture seule.

### Couche du conteneur vs volume

```
$ docker exec shop-db-1 touch /tmp/x
$ docker exec shop-db-1 sh -c 'echo test > /var/lib/postgresql/data/y'
$ docker diff shop-db-1
C /tmp
A /tmp/x
C /var/run/postgresql
A /var/run/postgresql/.s.PGSQL.5432
A /var/run/postgresql/.s.PGSQL.5432.lock
```

- `/tmp/x` apparaît dans `docker diff` : il est écrit dans la **couche writable** du conteneur (overlay2, dossier
  `upperdir` de `/var/lib/docker/overlay2/<id>/diff`). Il disparaît avec le conteneur ;
- `y` dans `/var/lib/postgresql/data` n'apparaît **pas** : c'est un volume, monté par dessus l'overlay, les écritures
  vont directement dans `/var/lib/docker/volumes/shop_pgdata/_data` et survivent au conteneur.

### Que devient `pgdata` ?

Testé sur une copie de la stack (`docker compose -p shopcopy ...`) :

| Commande | Conteneurs | Volume nommé `pgdata` |
|---|---|---|
| `docker compose down` | supprimés (+ réseaux) | **conservé** |
| `docker compose down -v` | supprimés | **supprimé** (les volumes nommés déclarés dans le compose + les anonymes) |
| `docker compose rm` (services arrêtés) | supprimés | conservé (`rm -v` supprime seulement les volumes anonymes) |
| `docker volume prune` | - | conservé : depuis Docker 23 `prune` ne supprime que les volumes **anonymes** inutilisés |
| `docker volume prune -a` | - | **supprimé** s'il n'est utilisé par aucun conteneur (même arrêté) |

```
$ docker compose -p shopcopy down
$ docker volume ls | grep shopcopy
local     shopcopy_pgdata
local     shopcopy_redisdata
$ docker compose -p shopcopy up -d --wait && docker compose -p shopcopy down -v
$ docker volume ls | grep shopcopy
$
```

D'où l'incident : `down -v` "pour nettoyer" efface la base sans rien demander.

### Volume anonyme

```
$ docker run -d --name pganon -e POSTGRES_PASSWORD=x postgres:16-alpine
$ docker inspect pganon --format '{{json .Mounts}}' | jq '.[0] | {Name, Source, Destination}'
{
  "Name": "4f9a1c3e0b...",
  "Source": "/var/lib/docker/volumes/4f9a1c3e0b.../_data",
  "Destination": "/var/lib/postgresql/data"
}
$ docker rm -f pganon
$ docker volume ls -f dangling=true
local     4f9a1c3e0b...
```

L'image postgres déclare `VOLUME /var/lib/postgresql/data` : sans `-v`, docker crée un volume avec un nom aléatoire.

- `docker rm` : le volume reste (orphelin) ;
- `docker rm -v` : le volume est supprimé avec le conteneur.

Le piège : un nouveau `docker run` crée un **nouveau** volume anonyme, la base est vide, on croit que les données sont
perdues alors qu'elles sont dans un volume qu'on ne sait pas retrouver. Et au contraire les volumes orphelins
s'accumulent et remplissent le disque, jusqu'au `prune` qui les efface tous (y compris celui qui contenait les données).

### Bind mount vs volume nommé vs tmpfs

| | Bind mount | Volume nommé | tmpfs |
|---|---|---|---|
| Où | un chemin de l'hôte choisi | géré par docker (`/var/lib/docker/volumes`) | RAM |
| Pour | code source en dev, fichiers de config, socket docker | données des bases, tout ce qui doit persister | fichiers temporaires, secrets en mémoire, `read_only` |
| Persistance | oui (c'est le FS de l'hôte) | oui, indépendant du conteneur | non, perdu à l'arrêt |
| Permissions | celles de l'hôte (problèmes d'uid fréquents) | initialisé avec le contenu et les droits de l'image | - |

Sur Docker Desktop (macOS/Windows) docker tourne dans une VM : un bind mount d'un dossier du Mac/Windows passe par un
partage de fichiers (virtiofs, gRPC FUSE, 9p pour WSL) qui est **beaucoup plus lent** (x3 à x10 sur beaucoup de petits
fichiers, `node_modules` par exemple) et les événements inotify passent mal. Un volume nommé reste dans le disque de la
VM, donc vitesse native. Sous Windows, mettre le code dans le FS de WSL2 règle le problème.

### Pourquoi `init.sql` n'est pas rejoué

Le `docker-entrypoint.sh` de postgres ne lance `initdb` puis les scripts de `/docker-entrypoint-initdb.d` **que si le
dossier de données est vide** (pas de `PG_VERSION`). Au redémarrage le volume contient déjà une base → rien n'est
rejoué. C'est voulu (sinon on réinitialiserait la prod à chaque restart).

Forcer une ré-initialisation : supprimer le volume (`docker compose down -v` ou `docker volume rm shop_pgdata`) puis
`up`. Ou, sans perdre les données, rejouer le script à la main :
`docker compose exec -T db psql -U shop -d shop < db/init.sql` (d'où l'intérêt des `IF NOT EXISTS`). Pour faire
évoluer un schéma existant, ce sont les migrations (`make migrate` du TP04).

## 2. Sauvegarde et restauration

`backup.sh` :

- `pg_dump -Fc` (format custom : compressé, restauration sélective et parallèle possible avec `pg_restore -j`) ;
- sauvegarde brute : `tar` du volume depuis un conteneur alpine monté en `:ro` ;
- rétention : garde les 7 derniers de chaque type.

**Quand la sauvegarde brute est incohérente** : si on copie les fichiers pendant que postgres tourne, une partie des
fichiers est copiée avant une écriture et une partie après (pages de tables, WAL, `pg_control` pas au même instant).
Le résultat peut ne pas démarrer ou contenir des données corrompues. Pour qu'elle soit cohérente :

- arrêter la base pendant la copie (ce que fait le script : quelques secondes d'indispo) ;
- ou à chaud : `SELECT pg_backup_start('label')`, copie, `SELECT pg_backup_stop()` **et** garder les WAL générés
  pendant la copie (c'est ce que fait `pg_basebackup`) ;
- ou un snapshot atomique du FS (LVM, ZFS, snapshot EBS).

Le dump logique, lui, est toujours cohérent (pg_dump travaille dans une transaction en snapshot) sans arrêter la base.

`restore.sh FICHIER` : `.dump` → `pg_restore --clean --if-exists` ; `.tar.gz` → base arrêtée, volume vidé, `tar x`.

Preuve (détail dans [TRANSCRIPT.md](TRANSCRIPT.md)) : seed → checksum → backup → `down -v` → `up` → restore →
même checksum, avec le dump et avec l'archive brute.

### Sidecar planifié

```bash
cd ../tp04-compose-entreprise && make up && cd -
docker compose -f ../tp04-compose-entreprise/compose.yml -f compose.backup.yml up -d --wait
docker compose -f ../tp04-compose-entreprise/compose.yml -f compose.backup.yml exec backup ls -l /backups/last
```

```
-rw-r--r-- 1 postgres postgres 1.2K Oct 29 11:04 shop-20261029-110400.sql.gz
-rw-r--r-- 1 postgres postgres 1.2K Oct 29 11:05 shop-20261029-110500.sql.gz
lrwxrwxrwx 1 postgres postgres   27 Oct 29 11:05 shop-latest.sql.gz -> shop-20261029-110500.sql.gz
```

Un dump par minute avec `SCHEDULE: "@every 1m"`, rangés dans `daily/`, `weekly/`, `monthly/` avec la rétention
`BACKUP_KEEP_*`. En vrai on mettrait `@daily` et un volume sur un autre disque / bucket.

## 3. Montée de version PostgreSQL 14 → 16

Changer juste le tag :

```
$ sed -i 's/postgres:14.13-alpine/postgres:16.4-alpine/' compose.yml && docker compose up -d
$ docker compose logs db
db-1  | PostgreSQL Database directory appears to contain a database; Skipping initialization
db-1  | 2026-10-29 10:31:02.114 UTC [1] FATAL:  database files are incompatible with server
db-1  | 2026-10-29 10:31:02.114 UTC [1] DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
db-1 exited with code 1
```

Pourquoi : le format des fichiers sur disque (catalogue système, `pg_control`) change entre deux versions **majeures**.
PostgreSQL 16 refuse de démarrer sur un dossier créé par la 14. Entre versions mineures (14.12 → 14.13) pas de souci.
Il faut soit exporter/réimporter (dump/restore), soit `pg_upgrade` qui a besoin des binaires des **deux** versions.

[upgrade-pg.sh](upgrade-pg.sh) :

1. checksum avant sur PG14 ;
2. `pg_dumpall` (filet de sécurité complet) + `pg_dump -Fc` de la base ;
3. arrêt de PG14, le volume `pgdata` n'est pas touché ;
4. PG16 sur un nouveau volume `pgdata16` (via [compose.pg16.yml](compose.pg16.yml)) ;
5. `pg_restore` + `ANALYZE` (les statistiques du planificateur ne sont pas dans le dump) ;
6. checksum après, comparaison, verdict (code de sortie 1 si différent).

**Retour arrière** : PG14 et son volume sont intacts, il suffit de relancer sans la surcharge :

```bash
docker compose -f compose.yml -f compose.pg16.yml stop db
docker compose -f compose.yml up -d --wait
```

Une fois validé, on reporte `postgres:16.4-alpine` et le volume `pgdata16` dans `compose.yml`, et on garde `pgdata`
quelques jours avant de le supprimer. Attention : les écritures faites sur PG16 après la bascule seraient perdues en
cas de retour arrière (il faudrait un dump de PG16 restauré sur PG14, ce qui ne marche pas toujours dans ce sens).

### Questions

**`pg_dumpall` vs `pg_dump`** : `pg_dump` exporte **une** base (schéma + données), en SQL ou en format custom/dir/tar
restaurable avec `pg_restore` (sélectif, parallèle). `pg_dumpall` exporte **tout le cluster** : toutes les bases +
les objets globaux (rôles, mots de passe, tablespaces) qu'un `pg_dump` ne contient pas, mais uniquement en SQL texte
(restauration avec `psql`). On fait souvent `pg_dumpall --globals-only` + un `pg_dump -Fc` par base.

**Pourquoi un nouveau volume** : pour garder l'ancien intact = retour arrière immédiat et sans risque. Si on vide
l'ancien volume pour y mettre PG16 et que la restauration échoue à moitié, on n'a plus que le dump (qu'il faut espérer
bon). Et un volume qui a démarré une fois en 16 n'est plus utilisable en 14.

**Réduire l'indisponibilité** : ici la coupure dure tout le dump + restore (proportionnel à la taille de la base).

- `pg_restore -j 4` (format custom ou directory) pour paralléliser ;
- `pg_upgrade --link` : convertit le catalogue et crée des **hard links** vers les fichiers de données au lieu de les
  copier, quelques secondes même pour des centaines de Go. Il faut les binaires 14 et 16 dans le même conteneur :
  image `tianon/postgres-upgrade:14-to-16`. Inconvénient : après démarrage en 16, l'ancien cluster n'est plus
  utilisable (fichiers partagés) → faire une sauvegarde avant ;
- **réplication logique** : PG16 abonné à PG14 (`CREATE PUBLICATION` / `CREATE SUBSCRIPTION`), on laisse la copie se
  faire pendant que la prod tourne, puis on bascule l'application → coupure de quelques secondes.

## 4. Redis

| Mode | Fonctionnement | Perte max |
|---|---|---|
| `--save 60 1` (RDB) | snapshot complet si au moins 1 écriture en 60 s | jusqu'à ~60 s d'écritures (tout ce qui est après le dernier snapshot), plus si le snapshot échoue |
| `--appendonly yes` (AOF, `appendfsync everysec` par défaut) | chaque écriture ajoutée à un journal, fsync chaque seconde | ~1 s |
| AOF + `appendfsync always` | fsync à chaque écriture | ~0, mais beaucoup plus lent |

Dans notre stack Redis contient :

- le **cache** `products` (TTL 30 s) : aucune valeur à persister, il se reconstruit depuis la base ;
- la **file** `orders:queue` : là c'est important, une commande poussée et pas encore consommée par le worker serait
  perdue (la commande reste `pending` en base et ne serait jamais traitée).

Donc AOF (`appendonly yes`, everysec) est justifié pour la file, c'est ce qui est configuré dans le TP04 (+ volume
`redisdata`). Une seconde de perte reste possible : pour une vraie file de commandes il faudrait plutôt un
vrai broker (RabbitMQ, Redis Streams avec acquittement) ou un job qui retraite les commandes restées `pending`.

## Bonus

### B1 - pg_upgrade --link

```bash
docker compose stop db
docker volume create shopdata_pgdata16
docker run --rm \
  -v shopdata_pgdata:/var/lib/postgresql/14/data \
  -v shopdata_pgdata16:/var/lib/postgresql/16/data \
  -e POSTGRES_INITDB_ARGS="--username=shop" -e PGUSER=shop \
  tianon/postgres-upgrade:14-to-16 --link
```

Problème avec `--link` + deux volumes : les hard links ne peuvent pas traverser deux systèmes de fichiers (deux
volumes = deux dossiers mais même FS en `local`, ça passe ; sur deux disques différents ça échoue). Le plus propre
est un seul volume monté sur `/var/lib/postgresql` avec les sous-dossiers `14/data` et `16/data`.

| | dump/restore | pg_upgrade --link |
|---|---|---|
| 100 000 commandes | ~6 s | ~3 s |

Sur une petite base la différence est faible (le démarrage des conteneurs domine), sur une base de 100 Go c'est des
heures contre quelques secondes.

### B2 - dump chiffré vers MinIO

```bash
docker run -d --name minio -p 9000:9000 -p 9001:9001 -e MINIO_ROOT_USER=admin -e MINIO_ROOT_PASSWORD=admin12345 \
  minio/minio:RELEASE.2024-09-22T00-33-43Z server /data --console-address :9001
age-keygen -o backup.key                                   # garder la clé privée HORS du serveur
age -r $(grep public backup.key | awk '{print $4}') -o shop.dump.age backups/shop-xxx.dump
docker run --rm --network host -v $PWD:/w minio/mc:RELEASE.2024-09-16T17-43-14Z \
  sh -c 'mc alias set local http://localhost:9000 admin admin12345 && mc mb -p local/backups && mc cp /w/shop.dump.age local/backups/'
```

### B3 - volume distant

```yaml
volumes:
  pgdata:
    driver: local
    driver_opts:
      type: nfs
      o: addr=10.0.0.10,nfsvers=4,rw
      device: ":/exports/pgdata"
```

Les données ne sont plus liées à la machine : un autre noeud peut remonter le volume si le serveur tombe. Mais :
une base sur NFS c'est risqué (latence, fsync, verrous), deux conteneurs ne doivent jamais monter les mêmes fichiers
postgres en même temps, et la sauvegarde reste nécessaire (le NFS réplique aussi un `DROP TABLE`). La HA d'une base
se fait plutôt par réplication (streaming replication, Patroni) que par le stockage.

### B4 - PITR

Activer l'archivage WAL (`archive_mode=on`, `archive_command='cp %p /wal/%f'` sur un volume `walarchive`), faire un
`pg_basebackup`, puis pour restaurer à T-5 min : restaurer le base backup dans un volume vide, créer `recovery.signal`
et `restore_command='cp /wal/%f %p'` + `recovery_target_time='2026-10-29 10:55:00'`, démarrer. Postgres rejoue les WAL
jusqu'à l'instant voulu.
