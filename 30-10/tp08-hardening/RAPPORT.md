# TP08 - Durcissement

Fichiers : [audit.sh](audit.sh), [compose.hardened.yml](compose.hardened.yml), [daemon.json](daemon.json).

`compose.hardened.yml` est une surcharge de la stack du TP04 :

```bash
cd ../../29-10/tp04-compose-entreprise
docker compose -f compose.yml -f ../../30-10/tp08-hardening/compose.hardened.yml up -d --wait
./smoke-test.sh
../../30-10/tp08-hardening/audit.sh
```

## 1. Mesurer

`audit.sh` lit `docker inspect` de chaque conteneur qui tourne (ou ceux passés en argument) et vérifie :
utilisateur, `Privileged`, `CapAdd`, `CapDrop` contient `ALL`, rootfs en lecture seule, limite mémoire, `PidsLimit`,
`no-new-privileges`, socket docker montée. Code retour 1 s'il y a au moins un écart.

### Avant (stack TP04, `compose.yml` + override dev)

```
$ ./audit.sh
CONTENEUR                    USER       PRIV  CAP_ADD                  DROP_ALL RO   MEMOIRE PIDS   NNP   SOCKET ECARTS
shop-api-1                   node       false -                        non      non  aucune  aucun  non   non    5 (cap_drop rootfs_rw memoire pids nnp)
shop-db-1                    root       false -                        non      non  aucune  aucun  non   non    6 (root cap_drop rootfs_rw memoire pids nnp)
shop-redis-1                 root       false -                        non      non  aucune  aucun  non   non    6 (root cap_drop rootfs_rw memoire pids nnp)
shop-traefik-1               root       false -                        non      non  aucune  aucun  non   OUI    7 (root cap_drop rootfs_rw memoire pids nnp socket)
shop-worker-1                10001      false -                        non      non  aucune  aucun  non   non    5 (cap_drop rootfs_rw memoire pids nnp)

total : 29 ecart(s) sur 5 conteneur(s)
```

29 écarts. L'api et le worker sont déjà non-root grâce aux Dockerfiles des TP01/TP02 ; db, redis et traefik
tournent en root (l'image n'a pas de `USER`), et Traefik a la socket docker.

Avec `compose.prod.yml` du TP04 c'est déjà mieux (read_only, cap_drop, nnp, limites mémoire) mais il reste
root sur db/redis/traefik, pas de `pids_limit` et la socket.

### docker-bench-security

```bash
docker run --rm --net host --pid host --userns host --cap-add audit_control \
  -v /etc:/etc:ro -v /var/lib:/var/lib:ro -v /var/run/docker.sock:/var/run/docker.sock:ro \
  docker/docker-bench-security
```

```
Section C - Score
[INFO] Checks: 117
[INFO] Score: 4
```

Le score part bas (beaucoup de WARN côté hôte, normal sur une machine de dev). Les 5 WARN que je trouve prioritaires :

| Check | WARN | Pourquoi prioritaire |
|---|---|---|
| 5.31 | Ensure that the Docker socket is not mounted inside any containers (`shop-traefik-1`) | socket = root sur l'hôte, et traefik est exposé sur Internet |
| 4.1 | Ensure that a user for the container has been created (db, redis, traefik) | une évasion arrive en root sur l'hôte |
| 5.10 / 5.11 | Ensure that the memory usage / CPU priority for containers is limited | un seul service peut saturer la machine (DoS) |
| 5.25 | Ensure that the container is restricted from acquiring additional privileges | élévation via setuid |
| 5.28 | Ensure that the PIDs cgroup limit is used | fork bomb = hôte qui ne répond plus |

D'autres sont moins urgents ou hors de notre périmètre : 2.x (config du daemon, traité en partie 4), 1.x
(audit auditd de l'hôte), 4.5 Content trust (on a cosign au TP03), 5.12 read-only rootfs (traité).
Sous Docker Desktop les sections 1 et 2 parlent de la VM et pas de Windows, elles ne veulent pas dire grand chose.

## 2. Expériences

| Mesure | Commande | Résultat | Conclusion |
|---|---|---|---|
| `--read-only` | `docker run --rm --read-only alpine touch /x` | `touch: /x: Read-only file system` | le FS du conteneur est figé |
| | `docker run --rm --read-only --tmpfs /tmp alpine touch /tmp/x` | OK | on ouvre uniquement les dossiers nécessaires, en RAM |
| `--cap-drop ALL` | `docker run --rm --cap-drop ALL alpine ping -c1 1.1.1.1` | `ping: permission denied (are you root?)` | besoin de `NET_RAW` (socket raw) |
| | `docker run --rm --cap-drop ALL alpine sh -c 'touch /tmp/x && chown 1000 /tmp/x'` | `chown: /tmp/x: Operation not permitted` | besoin de `CHOWN` : même root ne peut plus changer un propriétaire |
| | `docker run --rm --cap-drop ALL alpine apk add curl` | erreurs `Operation not permitted` à l'extraction | apk a besoin de `CHOWN`, `FOWNER`, `DAC_OVERRIDE` (et `SETGID`/`SETUID` pour certains paquets). On n'installe rien au runtime de toute façon : ça se fait dans le Dockerfile |
| `no-new-privileges` | `docker run --rm -u 1000 debian:12-slim grep NoNewPrivs /proc/self/status` | `NoNewPrivs: 0` | |
| | `docker run --rm -u 1000 --security-opt no-new-privileges debian:12-slim grep NoNewPrivs /proc/self/status` | `NoNewPrivs: 1` | le noyau ignore les bits setuid/setcap au `execve` |
| | `docker run --rm -it -u 1000 --security-opt no-new-privileges debian:12-slim passwd` | `passwd: Authentication token manipulation error` | `passwd` (setuid root) ne peut plus lire `/etc/shadow` : il tourne en uid 1000. Sans l'option il demande bien le mot de passe |
| `--pids-limit 50` | `docker run --rm --pids-limit 50 alpine sh -c 'for i in $(seq 100); do sleep 60 & done; sleep 1; ps \| wc -l'` | ~50 lignes + `can't fork: Resource temporarily unavailable` | au-delà de 50 process le `fork` échoue, une fork bomb reste dans le conteneur |
| `--memory 32m` | `docker run --name oom --memory 32m --memory-swap 32m python:3.12-alpine python -c "x='a'*100_000_000"` puis `docker inspect oom -f '{{.State.OOMKilled}} {{.State.ExitCode}}'` | `true 137` | le noyau tue le process du cgroup (137 = SIGKILL) |
| `--user 1000` | `docker run --rm --user 1000 alpine id` | `uid=1000 gid=0(root) groups=0(root)` | pas d'entrée dans `/etc/passwd` mais ça marche ; gid 0 par défaut, mettre `1000:1000` |
| | `docker run --rm --user 1000 -v test:/data alpine touch /data/x` | `touch: /data/x: Permission denied` | un volume neuf appartient à root : il faut que l'image crée le dossier avec le bon propriétaire (le volume hérite alors des droits), ou un `chown` une fois |
| seccomp | `docker run --rm alpine unshare --user id` | `unshare: unshare(0x10000000): Operation not permitted` | le profil par défaut bloque `unshare` avec les flags de namespace (sans CAP_SYS_ADMIN) |
| | `docker run --rm --security-opt seccomp=unconfined alpine unshare --user id` | `uid=65534(nobody) gid=65534(nobody)` | sans seccomp le conteneur peut créer des user namespaces (grosse surface d'attaque noyau) |

Le profil seccomp par défaut est une liste blanche d'environ 300+ syscalls autorisés ; il en bloque **une
quarantaine** (44 d'après la doc docker), dont `mount`, `reboot`, `kexec_load`, `init_module`, `ptrace` (selon le
noyau), `unshare`/`clone` avec namespaces, `keyctl`, `bpf`, `perf_event_open`...

## 3. Stack durcie

[compose.hardened.yml](compose.hardened.yml), chaque directive est commentée avec la menace qu'elle réduit.

### Capabilities par service

| Service | Utilisateur | cap_add | Pourquoi |
|---|---|---|---|
| api | node (1000) | aucune | process non-root, n'a besoin d'aucun privilège |
| worker | 10001 | aucune | idem |
| db | postgres (70) | aucune | voir dessous |
| redis | redis (999) | aucune | idem postgres |
| traefik | nobody (65534) | aucune | voir dessous |
| socket-proxy | root | aucune | doit lire la socket (`root:docker 660`) |

**PostgreSQL** : lancé en root (comme au TP04 prod), l'entrypoint fait des `chown`/`chmod` sur `PGDATA` puis repasse
en utilisateur `postgres` avec `su-exec`. En `cap_drop: ALL`, il échoue :

```
chown: /var/lib/postgresql/data: Operation not permitted
```

Par essai/erreur il faut `CHOWN`, `DAC_OVERRIDE`, `FOWNER` (chmod de fichiers qui ne lui appartiennent pas),
`SETUID` et `SETGID` (su-exec). C'est ce qu'il y a dans `compose.prod.yml` du TP04.
Mieux : lancer directement en `user: "70:70"`. L'entrypoint voit qu'il n'est pas root, saute les chown et lance
postgres. Le volume `pgdata` appartient déjà à `postgres` (créé par l'image), donc ça marche sans **aucune**
capability. Même principe pour redis (`999:1000`).

**Traefik** : en root il a besoin de `NET_BIND_SERVICE` pour écouter sur 80 (< 1024). En `user: 65534` les
capabilities ne servent plus à rien (elles ne sont pas dans l'ensemble effectif d'un process non-root), mais docker
met par défaut `net.ipv4.ip_unprivileged_port_start=0` dans le namespace réseau du conteneur : un utilisateur
normal peut écouter sur 80. Je le remets explicitement dans `sysctls` pour ne pas dépendre de la version de docker.

### Socket proxy

La socket montée dans Traefik = n'importe qui qui prend la main sur Traefik peut faire `docker run --privileged -v /:/host`
et devient root sur l'hôte. Maintenant :

- `tecnativa/docker-socket-proxy` (haproxy) est le seul à monter la socket, en `:ro` ;
- il ne laisse passer que `GET` sur `/containers`, `/events`, `/version`, `/_ping` (`POST: 0`) ;
- il est sur le réseau `socket` en `internal: true`, joignable seulement par Traefik ;
- Traefik utilise `TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=tcp://socket-proxy:2375`.

Si Traefik est compromis, l'attaquant peut lister les conteneurs (et lire leurs variables d'env, d'où les secrets
en fichier) mais ne peut plus en créer ni exécuter de commande.

### Vérification

```
$ docker compose -f compose.yml -f ../../30-10/tp08-hardening/compose.hardened.yml up -d --wait
$ ./smoke-test.sh
-- /ready
  [ok] db et redis ok
-- /products et cache redis
  [ok] X-Cache: HIT
-- commande
  [ok] commande creee (pending)
  [ok] commande confirmee par le worker
smoke test ok

$ ../../30-10/tp08-hardening/audit.sh
CONTENEUR                    USER       PRIV  CAP_ADD                  DROP_ALL RO   MEMOIRE PIDS   NNP   SOCKET ECARTS
shop-api-1                   node       false -                        oui      oui  256M    100    oui   non    ok
shop-db-1                    70:70      false -                        oui      oui  512M    200    oui   non    ok
shop-redis-1                 999:1000   false -                        oui      oui  128M    50     oui   non    ok
shop-socket-proxy-1          root       false -                        oui      non  64M     100    oui   OUI    3 (root rootfs_rw socket)
shop-traefik-1               65534:65534 false -                       oui      oui  128M    100    oui   non    ok
shop-worker-1                10001      false -                        oui      oui  128M    50     oui   non    ok

total : 3 ecart(s) sur 6 conteneur(s)

$ ../../30-10/tp08-hardening/audit.sh shop-api-1 shop-worker-1 shop-db-1 shop-redis-1 shop-traefik-1
...
total : 0 ecart(s) sur 5 conteneur(s)
```

Il reste 3 écarts **acceptés** sur le socket-proxy : c'est son rôle de monter la socket, il doit être root pour la
lire, et son entrypoint écrit la config haproxy au démarrage. On a concentré le risque dans un composant minuscule,
sans port publié, sur un réseau interne, qui filtre l'API.

Avec l'override dev du TP04 chargé, le bind mount du code est en `:ro` : compatible avec `read_only`, et
`node --watch` continue de marcher. Rien à changer.

## 4. Côté daemon

[daemon.json](daemon.json) (`/etc/docker/daemon.json`, puis `systemctl restart docker`) :

| Option | Effet |
|---|---|
| `no-new-privileges: true` | appliqué à tous les conteneurs par défaut, même ceux lancés à la main |
| `icc: false` | pas de communication entre conteneurs sur le bridge **par défaut** (`docker0`) |
| `live-restore: true` | les conteneurs continuent de tourner pendant un redémarrage/mise à jour du daemon |
| `userland-proxy: false` | les ports publiés passent par iptables, plus de process `docker-proxy` par port |
| `log-driver: local` + rotation | plus jamais de disque plein à cause des logs, même pour un `docker run` oublié |
| `userns-remap: default` | root dans le conteneur = uid 100000+ sur l'hôte (utilisateur `dockremap`) |
| `default-ulimits` | limite de fichiers ouverts homogène |

**Effet de bord de `icc: false`** : aucun sur notre stack. L'option ne concerne que le bridge par défaut
`docker0`. Les réseaux créés par compose (`shop_front`, `shop_back`) sont des réseaux utilisateurs avec leur propre
option `com.docker.network.bridge.enable_icc` (true par défaut), donc l'api parle toujours à la base. Ce qui casse :
les vieux `docker run --link` sur le bridge par défaut.

**Effet de bord de `userns-remap`** :

- docker change de dossier de données (`/var/lib/docker/100000.100000/`) : toutes les images, conteneurs et
  **volumes existants disparaissent** de la vue de docker (ils sont toujours sur le disque, dans l'ancien dossier) ;
- si on recopie les volumes, les fichiers appartiennent à `postgres` (70) de l'hôte, alors que dans le conteneur
  postgres est maintenant 100070 sur l'hôte → `permission denied`. Il faut `chown -R` en décalant de 100000 ;
- les bind mounts posent le même problème (fichiers de l'hôte vus comme `nobody`) ;
- incompatible avec `--privileged`, `--pid=host`, `--net=host` sauf `--userns=host` par conteneur (cAdvisor du
  TP07, docker-bench-security).

**Rootless** à la place : le daemon lui-même tourne sans root. Plus sûr (même une évasion du daemon n'est pas root)
mais plus de limites (voir B2). Je le mettrais sur les postes de dev et les runners CI, `userns-remap` sur un
serveur existant qu'on ne veut pas réinstaller.

## Bonus

### B1 - seccomp personnalisé

```bash
docker run --rm --cap-add SYS_PTRACE --security-opt seccomp=unconfined -p 3000:3000 \
  --entrypoint sh shop/shopapi:dev -c 'apk add --no-cache strace >/dev/null && strace -f -c -o /tmp/s node src/server.js & sleep 20; cat /tmp/s'
# en parallele : ./load.sh 500
```

On récupère la liste des syscalls réellement utilisés (une soixantaine pour node : `epoll_*`, `read`, `write`,
`mmap`, `futex`, `accept4`, `openat`, `statx`...), on part du profil par défaut de moby
(`profiles/seccomp/default.json`), on met `defaultAction: SCMP_ACT_ERRNO` et on ne garde dans `names` que cette
liste + une marge (syscalls du démarrage, de la gestion d'erreur, du GC). Puis :

```yaml
  api:
    security_opt:
      - seccomp=./seccomp/api.json
```

Il faut rejouer tous les chemins de code (erreurs, arrêt SIGTERM, reconnexion redis) sinon l'appli plante plus tard
sur un syscall oublié. `docker-slim` (`mint`) fait ça automatiquement en observant le conteneur.

### B2 - rootless

```bash
dockerd-rootless-setuptool.sh install   # (paquet docker-ce-rootless-extras)
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
```

Ce qui ne marche plus :

- **ports < 1024** (Traefik sur 80) : `sysctl net.ipv4.ip_unprivileged_port_start=80` sur l'hôte, ou publier 8080 et
  rediriger avec iptables, ou `setcap cap_net_bind_service=ep $(which rootlesskit)` ;
- **cAdvisor** et docker-bench : pas d'accès aux cgroups / au vrai `/var/lib/docker` ; les limites CPU/mémoire
  demandent cgroup v2 + délégation systemd (`Delegate=yes`) ;
- **performances réseau** : le réseau passe par `slirp4netns` / `pasta` en espace utilisateur, plus lent (installer
  `pasta` ou `bypass4netns`) ; l'IP source des clients est perdue avec le port driver par défaut ;
- overlay2 nécessite un noyau récent (sinon `fuse-overlayfs`, plus lent).

### B3 - distroless + docker scout

L'image distroless existe déjà au TP01 (`shopapi/Dockerfile.distroless`).

```bash
docker scout cves shopapi:1.4.2
docker scout cves shopapi:1.4.2-distroless
docker scout recommendations shopapi:1.4.2
```

La version distroless a beaucoup moins de paquets OS (pas de busybox, pas d'apk, pas de shell), donc moins de CVE
remontées. `recommendations` propose de passer à un tag plus récent de l'image de base quand il corrige des CVE.

### B4 - AppArmor

`docker-default` est appliqué automatiquement (si AppArmor est actif) : interdit `mount`, l'écriture dans
`/proc/sys`, `/sys`, etc. Profil dédié qui interdit l'écriture hors `/tmp` :

```
#include <tunables/global>
profile shop-api flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  network inet tcp,
  network inet udp,
  file,
  deny /** w,
  /tmp/** rw,
  deny mount,
  deny /proc/sys/** w,
  deny /sys/** w,
}
```

```bash
sudo apparmor_parser -r -W apparmor/shop-api
docker run --security-opt apparmor=shop-api ...
```

Ça fait doublon avec `read_only: true` pour l'écriture, mais AppArmor s'applique aussi aux volumes montés en
écriture et aux process lancés par l'appli.
