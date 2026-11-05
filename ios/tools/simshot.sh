#!/bin/bash
# Capture de l'app dans le Simulateur iOS — UNIQUEMENT l'écran du simulateur (jamais l'écran du Mac).
#   tools/simshot.sh <sortie.png> [--wait=6] [--args="-sim 90 -speedup 6 -onboarded YES"] [--url=osamaps://…]… [--then=8 --url=…] [--reboot]
# Exemple : tools/simshot.sh /tmp/x.png --args="-sim 60 -onboarded YES" --url="osamaps://go?name=Vichy&lat=46.1278&lng=3.4258" --wait=8
# Un seul simulateur partagé « OsaMaps-Test », utilisé par un agent à la fois (verrou) :
# installe TA build (build/…/OsaMaps.app du worktree courant), lance, ouvre les liens, attend, capture.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$1; shift
APP=build/Build/Products/Debug-iphonesimulator/OsaMaps.app
[ -d "$APP" ] || { echo "Construis d'abord : ./build.sh"; exit 1; }
exec tools/slot.sh sim 1 python3 tools/simshot.py "$OUT" "$APP" "$@"
