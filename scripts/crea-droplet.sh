#!/bin/bash
# Rigenera il droplet "Crea DMG.app" dal sorgente AppleScript, dichiarando
# l'accettazione di app e cartelle nel drag & drop (osacompile da solo
# accetta soltanto file semplici) e rifirmandolo.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
rm -rf "Crea DMG.app"
osacompile -o "Crea DMG.app" scripts/crea-dmg-droplet.applescript
P="Crea DMG.app/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Delete :CFBundleDocumentTypes:0" \
  -c "Add :CFBundleDocumentTypes:0 dict" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Applicazione o cartella'" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.item" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string com.apple.package" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:2 string public.folder" \
  "$P"
codesign --force -s - "Crea DMG.app"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$DIR/Crea DMG.app"
echo "Droplet rigenerato: $DIR/Crea DMG.app"
