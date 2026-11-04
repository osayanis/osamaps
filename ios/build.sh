#!/bin/bash
# Construit OsaMaps pour le Simulateur iOS (sans signature) : ./build.sh
# Sortie : build/Build/Products/Debug-iphonesimulator/OsaMaps.app
# Au plus 3 compilations simultanées sur le Mac (tools/slot.sh).
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
tools/slot.sh build 3 xcodebuild -project OsaMaps.xcodeproj -scheme OsaMaps -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
test -d build/Build/Products/Debug-iphonesimulator/OsaMaps.app
