#!/bin/bash
# Installe OsaMaps sur l'iPhone branché (ou appairé en Wi-Fi) : ./install.sh
# Compte Apple gratuit : l'app expire au bout de 7 jours, il suffit de relancer ce script.
# Équipe : détectée dans Xcode (Réglages > Comptes) ; sinon TEAM=XXXXXXXXXX ./install.sh
# iPhone : le premier trouvé ; sinon DEVICE=<UDID> ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
  | grep -E 'teamID' | head -1 | sed -E 's/.*= "?([A-Z0-9]+)"?;/\1/')}"
[ -n "$TEAM" ] || { echo "Aucune équipe : ouvre Xcode > Réglages > Comptes et ajoute ton identifiant Apple."; exit 1; }

DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}"
[ -n "$DEVICE" ] || { echo "Aucun iPhone disponible : branche-le, déverrouille-le et accepte « Faire confiance »."; exit 1; }

echo "Équipe $TEAM, iPhone $DEVICE"
xcodegen generate -q
tools/slot.sh build 3 xcodebuild -project OsaMaps.xcodeproj -scheme OsaMaps -configuration Release \
  -destination generic/platform=iOS -derivedDataPath build-device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=build-device/Build/Products/Release-iphoneos/OsaMaps.app
test -d "$APP" || { echo "Échec de la compilation."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installé. Premier lancement : Réglages > Général > VPN et gestion de l'appareil > faire confiance au développeur."
