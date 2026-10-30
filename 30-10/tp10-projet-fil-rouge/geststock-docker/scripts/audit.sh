#!/usr/bin/env bash
# audit.sh [CONTENEUR...]
# audit de durcissement des conteneurs en cours d'execution (tous si aucun argument)
# code retour 1 si au moins un ecart
set -euo pipefail

if [ $# -gt 0 ]; then
  containers=("$@")
else
  mapfile -t containers < <(docker ps --format '{{.Names}}' | sort)
fi
[ ${#containers[@]} -gt 0 ] || { echo "aucun conteneur"; exit 0; }

FMT='{{.Name}}|{{.Config.User}}|{{.HostConfig.Privileged}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.CapDrop}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}|{{json .HostConfig.SecurityOpt}}|{{range .Mounts}}{{.Source}} {{end}}'

total=0
printf '%-28s %-10s %-5s %-24s %-8s %-4s %-7s %-6s %-5s %-6s %s\n' \
  CONTENEUR USER PRIV CAP_ADD DROP_ALL RO MEMOIRE PIDS NNP SOCKET ECARTS

for c in "${containers[@]}"; do
  IFS='|' read -r name user priv capadd capdrop ro mem pids secopt mounts < <(docker inspect --format "$FMT" "$c")
  name=${name#/}
  ecarts=()

  case "$user" in ""|root|0|root:*|0:*) ecarts+=(root); user=${user:-root} ;; esac
  [ "$priv" = "true" ] && ecarts+=(privileged)

  capadd=$(echo "$capadd" | tr -d '[]"' | sed 's/null//')
  [ -z "$capadd" ] && capadd="-"

  if echo "$capdrop" | grep -q '"ALL"'; then dropall=oui; else dropall=non; ecarts+=(cap_drop); fi
  if [ "$ro" = "true" ]; then ro=oui; else ro=non; ecarts+=(rootfs_rw); fi
  if [ "$mem" = "0" ]; then mem=aucune; ecarts+=(memoire); else mem="$((mem / 1024 / 1024))M"; fi
  case "$pids" in ""|"<nil>"|0|-1) pids=aucun; ecarts+=(pids) ;; esac
  if echo "$secopt" | grep -q 'no-new-privileges'; then nnp=oui; else nnp=non; ecarts+=(nnp); fi
  if echo "$mounts" | grep -q 'docker.sock'; then sock=OUI; ecarts+=(socket); else sock=non; fi

  if [ ${#ecarts[@]} -gt 0 ]; then
    res="${#ecarts[@]} (${ecarts[*]})"
    total=$((total + ${#ecarts[@]}))
  else
    res="ok"
  fi
  printf '%-28s %-10s %-5s %-24s %-8s %-4s %-7s %-6s %-5s %-6s %s\n' \
    "$name" "$user" "$priv" "$capadd" "$dropall" "$ro" "$mem" "$pids" "$nnp" "$sock" "$res"
done

echo
echo "total : $total ecart(s) sur ${#containers[@]} conteneur(s)"
[ "$total" -eq 0 ]
