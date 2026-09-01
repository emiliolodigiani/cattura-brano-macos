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
OUT="$(dirname "$APP")/Cattura Brano.dmg"

rm -f "$OUT"
create-dmg \
  --volname "Cattura Brano" \
  --background "$DIR/dmg-sfondo.png" \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "Cattura Brano.app" 165 200 \
  --app-drop-link 495 200 \
  --hide-extension "Cattura Brano.app" \
  "$OUT" "$APP"

echo "Creato: $OUT"
