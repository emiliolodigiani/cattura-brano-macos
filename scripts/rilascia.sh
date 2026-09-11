#!/bin/bash
#
# Rilascio completo di Cattura Brano da riga di comando, senza passare
# dall'Organizer di Xcode: archivia, esporta l'app firmata con Developer ID,
# la notarizza e le incorpora il biglietto, crea il DMG, notarizza anche
# quello, verifica tutto con Gatekeeper e pubblica la release su GitHub con
# il DMG allegato.
#
# Uso:
#   scripts/rilascia.sh            rilascio completo (serve l'albero git pulito)
#   scripts/rilascia.sh --prova    solo archivio, esportazione e DMG, senza
#                                  notarizzazione né pubblicazione: per provare
#                                  la compilazione in locale
#   scripts/rilascia.sh --note F   usa il file F come note della release al
#                                  posto dell'elenco dei commit
#
# Prerequisiti:
#   - Xcode con l'account Apple Developer collegato (Xcode › Settings › Accounts);
#   - create-dmg e gh da Homebrew, con gh autenticato (gh auth login);
#   - un profilo di credenziali per notarytool nel portachiavi, da creare una
#     volta sola con una chiave API di App Store Connect (ruolo Developer,
#     file .p8 conservato in ~/.appstoreconnect/private_keys/):
#       xcrun notarytool store-credentials "notarizzazione" \
#         --key ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 \
#         --key-id <ID chiave> --issuer <ID emittente>
#     (in alternativa: --apple-id <Apple ID> --team-id 99V4TJ55YX, con una
#     "password specifica per le app" creata su https://account.apple.com).
#
# La versione (1.1.N, con N = numero di commit) è calcolata dal progetto in
# fase di compilazione: per questo il rilascio parte solo da un albero git
# pulito, così il tag vN corrisponde esattamente al codice compilato.
# Tutto il lavoro finisce in dist/<versione>/ (archivio, app, DMG, log).
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PROGETTO="$ROOT/cattura brano.xcodeproj"
SCHEMA="Cattura Brano"
TEAM_ID="99V4TJ55YX"
PROFILO_NOTARIZZAZIONE="notarizzazione"
DIST="$ROOT/dist"

PROVA=0
NOTE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prova) PROVA=1 ;;
    --note) NOTE_FILE="${2:?--note richiede un file}"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opzione sconosciuta: $1 (vedi --help)" >&2; exit 2 ;;
  esac
  shift
done

passo()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
errore() { printf '\n\033[31mErrore: %s\033[0m\n' "$*" >&2; exit 1; }

# MARK: Prerequisiti (tutti i controlli prima della compilazione, che è lunga)

passo "Controllo dei prerequisiti"
command -v xcodebuild >/dev/null || errore "xcodebuild non trovato: serve Xcode."
command -v create-dmg >/dev/null || errore "create-dmg non trovato: brew install create-dmg"
if [ "$PROVA" -eq 0 ]; then
  command -v gh >/dev/null || errore "gh non trovato: brew install gh"
  gh auth status >/dev/null 2>&1 || errore "gh non è autenticato: esegui gh auth login"
  if [ -n "$NOTE_FILE" ] && [ ! -f "$NOTE_FILE" ]; then
    errore "File delle note non trovato: $NOTE_FILE"
  fi
  [ -z "$(git -C "$ROOT" status --porcelain)" ] \
    || errore "L'albero git non è pulito: committa o scarta le modifiche (la versione deriva dai commit)."
  if ! xcrun notarytool history --keychain-profile "$PROFILO_NOTARIZZAZIONE" >/dev/null 2>&1; then
    errore "Manca il profilo notarytool \"$PROFILO_NOTARIZZAZIONE\" (o le credenziali non sono valide). Crealo una volta sola con una chiave API di App Store Connect:
  xcrun notarytool store-credentials \"$PROFILO_NOTARIZZAZIONE\" --key ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 --key-id <ID chiave> --issuer <ID emittente>
(oppure con --apple-id <Apple ID> --team-id $TEAM_ID e una \"password specifica per le app\"; vedi l'intestazione dello script)."
  fi
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
PROGRESSIVO="$(git -C "$ROOT" rev-list --count HEAD)"
MARKETING="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$PROGETTO/project.pbxproj" | head -1)"
[ -n "$MARKETING" ] || errore "MARKETING_VERSION non trovata nel progetto."
VERSIONE="$MARKETING.$PROGRESSIVO"
TAG="v$VERSIONE"
echo "Versione da rilasciare: $VERSIONE (commit ${COMMIT:0:7})"

if [ "$PROVA" -eq 0 ]; then
  git -C "$ROOT" fetch --tags --quiet origin
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    errore "Il tag $TAG esiste già: questa versione è già stata rilasciata. Serve almeno un nuovo commit."
  fi
fi

LAVORO="$DIST/$VERSIONE"
ARCHIVIO="$LAVORO/Cattura Brano.xcarchive"
ESPORTAZIONE="$LAVORO/esportazione"
rm -rf "$LAVORO"
mkdir -p "$LAVORO"

# MARK: Compilazione ed esportazione

passo "Archiviazione (Release, arm64)"
if ! xcodebuild archive \
    -project "$PROGETTO" -scheme "$SCHEMA" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVIO" \
    -allowProvisioningUpdates \
    -quiet > "$LAVORO/archiviazione.log" 2>&1; then
  tail -40 "$LAVORO/archiviazione.log"
  errore "Archiviazione non riuscita (log completo: $LAVORO/archiviazione.log)"
fi

passo "Esportazione con firma Developer ID"
OPZIONI="$LAVORO/opzioni-esportazione.plist"
cat > "$OPZIONI" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVIO" -exportOptionsPlist "$OPZIONI" -exportPath "$ESPORTAZIONE" \
    -allowProvisioningUpdates \
    -quiet > "$LAVORO/esportazione.log" 2>&1; then
  tail -40 "$LAVORO/esportazione.log"
  errore "Esportazione non riuscita (log completo: $LAVORO/esportazione.log)"
fi

APP="$ESPORTAZIONE/Cattura Brano.app"
[ -d "$APP" ] || errore "Esportazione non riuscita: manca \"$APP\""
VERSIONE_APP="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$VERSIONE_APP" = "$VERSIONE" ] \
  || errore "L'app esportata ha versione $VERSIONE_APP, attesa $VERSIONE."
codesign --verify --deep --strict "$APP" || errore "La firma dell'app non è valida."
FIRMA="$(codesign -dvv "$APP" 2>&1)"
echo "$FIRMA" | grep -q "Authority=Developer ID Application" \
  || { echo "$FIRMA"; errore "L'app non è firmata con Developer ID."; }
echo "App esportata: $APP"

# MARK: Notarizzazione

# Invia un file ad Apple e aspetta l'esito; in caso di rifiuto mostra il
# rapporto del servizio, che elenca i problemi trovati.
notarizza() {
  local file="$1"
  local log="$LAVORO/notarizzazione-$(basename "$file").log"
  if ! xcrun notarytool submit "$file" --keychain-profile "$PROFILO_NOTARIZZAZIONE" --wait \
        > "$log" 2>&1 || ! grep -q "status: Accepted" "$log"; then
    cat "$log"
    local id
    id="$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' "$log" | head -1)"
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --keychain-profile "$PROFILO_NOTARIZZAZIONE" || true
    fi
    errore "Notarizzazione di $(basename "$file") non riuscita (dettagli sopra)."
  fi
}

# Incorpora il biglietto di notarizzazione, così Gatekeeper lo trova anche
# senza rete.
incorpora_biglietto() {
  local file="$1"
  if ! xcrun stapler staple "$file" > "$LAVORO/stapler.log" 2>&1; then
    cat "$LAVORO/stapler.log"
    errore "Impossibile incorporare il biglietto in $(basename "$file")."
  fi
}

if [ "$PROVA" -eq 0 ]; then
  passo "Notarizzazione dell'app (può richiedere qualche minuto)"
  ZIP="$LAVORO/Cattura Brano.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarizza "$ZIP"
  incorpora_biglietto "$APP"
  rm -f "$ZIP"
fi

# MARK: DMG

passo "Creazione del DMG"
if ! "$DIR/crea-dmg.sh" "$APP" > "$LAVORO/crea-dmg.log" 2>&1; then
  tail -20 "$LAVORO/crea-dmg.log"
  errore "Creazione del DMG non riuscita (log: $LAVORO/crea-dmg.log)"
fi
DMG="$(sed -n 's/^Creato: //p' "$LAVORO/crea-dmg.log" | tail -1)"
[ -f "$DMG" ] || errore "DMG non trovato dopo la creazione."

# Il DMG viene firmato solo se nel portachiavi c'è un certificato Developer ID
# con chiave privata locale. Con la firma gestita da Xcode nel cloud non c'è,
# e il DMG resta senza firma: la notarizzazione e il biglietto valgono lo stesso.
IDENTITA="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o "\"Developer ID Application: [^\"]*($TEAM_ID)\"" | head -1 | tr -d '"' || true)"
DMG_FIRMATO=0
if [ -n "$IDENTITA" ]; then
  passo "Firma del DMG"
  codesign --sign "$IDENTITA" --timestamp "$DMG"
  DMG_FIRMATO=1
else
  echo "Nessun certificato Developer ID con chiave locale: il DMG non viene firmato."
fi

if [ "$PROVA" -eq 0 ]; then
  passo "Notarizzazione del DMG (può richiedere qualche minuto)"
  notarizza "$DMG"
  incorpora_biglietto "$DMG"
fi

# MARK: Verifica finale

passo "Verifica"
MONTAGGIO="$(hdiutil attach -nobrowse -readonly "$DMG" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)"
[ -d "$MONTAGGIO/Cattura Brano.app" ] || { hdiutil detach "$MONTAGGIO" -quiet; errore "L'app manca dentro il DMG."; }
if [ "$PROVA" -eq 0 ]; then
  ESITO="$(spctl -a -vv -t exec "$MONTAGGIO/Cattura Brano.app" 2>&1 || true)"
  hdiutil detach "$MONTAGGIO" -quiet
  echo "$ESITO" | grep -q "source=Notarized Developer ID" \
    || { echo "$ESITO"; errore "Gatekeeper non accetta l'app dentro il DMG."; }
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || errore "Il biglietto non risulta incorporato nel DMG."
  echo "Gatekeeper accetta l'app (Notarized Developer ID); biglietto presente in app e DMG."
else
  hdiutil detach "$MONTAGGIO" -quiet
  echo "DMG montabile con l'app dentro (non notarizzata: modalità prova)."
fi

if [ "$PROVA" -eq 1 ]; then
  passo "Prova completata"
  echo "DMG di prova (non notarizzato, non pubblicato): $DMG"
  exit 0
fi

# MARK: Pubblicazione

passo "Pubblicazione su GitHub ($TAG)"
git -C "$ROOT" push --quiet origin HEAD

NOTE="$LAVORO/note.md"
if [ -n "$NOTE_FILE" ]; then
  cp "$NOTE_FILE" "$NOTE"
else
  PRECEDENTE="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  {
    if [ -n "$PRECEDENTE" ]; then
      echo "Novità rispetto alla versione ${PRECEDENTE#v}:"
      echo
      git -C "$ROOT" log --no-merges --pretty='- %s' "$PRECEDENTE..HEAD"
    else
      echo "Prima versione pubblicata."
    fi
    echo
    if [ "$DMG_FIRMATO" -eq 1 ]; then
      echo "**Installazione.** Aprire il DMG e trascinare l'app in Applicazioni. App e DMG sono firmati con Developer ID e notarizzati da Apple. La separazione degli stem richiede Demucs, che l'app propone di installare al primo uso."
    else
      echo "**Installazione.** Aprire il DMG e trascinare l'app in Applicazioni. L'app è firmata con Developer ID; app e DMG sono notarizzati da Apple. La separazione degli stem richiede Demucs, che l'app propone di installare al primo uso."
    fi
    echo
    echo "Richiede macOS 14 o successivo su Apple Silicon."
  } > "$NOTE"
fi

gh release create "$TAG" "$DMG" \
  --target "$COMMIT" \
  --title "Cattura Brano $VERSIONE" \
  --notes-file "$NOTE" \
  --latest
git -C "$ROOT" fetch --tags --quiet origin

passo "Rilascio completato"
echo "Versione: $VERSIONE (commit ${COMMIT:0:7}, tag $TAG)"
echo "DMG:      $DMG"
echo "Release:  $(gh release view "$TAG" --json url --jq .url)"
echo "Le note della release si possono ritoccare su GitHub."
