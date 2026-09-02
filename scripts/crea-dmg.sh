#!/bin/bash
#
# Crea il DMG di distribuzione di Cattura Brano: icona dell'app a sinistra,
# freccia e alias della cartella Applicazioni a destra.
#
# Uso: scripts/crea-dmg.sh "/percorso/della/Cattura Brano.app"
# (di solito l'app esportata dall'Organizer con "Export Notarized App")
#
set -euo pipefail

APP="${1:?Indica il percorso di \"Cattura Brano.app\"}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Versione e numero di build letti dall'app, per il nome del file:
# "Cattura Brano 1.1 (20).dmg".
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
NAME="Cattura Brano"
VOLNAME="Cattura Brano"
if [ -n "$VERSION" ]; then
  NAME="$NAME $VERSION"
  VOLNAME="$VOLNAME $VERSION"
  # Il numero di build va aggiunto solo se la versione non lo contiene già
  # (lo schema attuale produce versioni tipo "1.1.26" con progressivo incluso).
  if [ -n "$BUILD" ] && [ "${VERSION##*.}" != "$BUILD" ]; then
    NAME="$NAME ($BUILD)"
  fi
fi
OUT="$(dirname "$APP")/$NAME.dmg"

rm -f "$OUT"
create-dmg \
  --volname "$VOLNAME" \
  --background "$DIR/dmg-sfondo.png" \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "Cattura Brano.app" 165 200 \
  --app-drop-link 495 200 \
  --hide-extension "Cattura Brano.app" \
  "$OUT" "$APP"

echo "Creato: $OUT"
