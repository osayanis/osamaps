#!/bin/bash
# slot.sh <nom> <n> <commande…> : exécute la commande en ne laissant que <n> exécutions simultanées
# de <nom> sur ce Mac (plusieurs agents/worktrees en parallèle : 16 Go de RAM).
name=$1; n=$2; shift 2
dir=/tmp/osamaps-locks; mkdir -p "$dir"
while true; do
  for i in $(seq 1 "$n"); do
    lockf -s -t 0 "$dir/$name.$i" "$@"
    rc=$?
    [ $rc -ne 75 ] && exit $rc   # 75 = verrou pris par un autre
  done
  sleep $((RANDOM % 4 + 2))
done
