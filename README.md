# Cattura Brano

App macOS (14+, Apple Silicon da M1 in poi) che cattura un brano
dall'audio di sistema o da un'interfaccia audio e lo rifinisce da sé:
ritaglio del silenzio in testa e in coda, normalizzazione, esportazione
MP3 o WAV, rilevamento dei BPM e, volendo, separazione degli stem
(voce, batteria, basso, altro) con Demucs, con la traccia batteria in
evidenza su sottofondo regolabile.

## Installazione

Il DMG notarizzato si scarica dalla pagina delle
[Release](https://github.com/emiliolodigiani/cattura-brano-macos/releases):
aprirlo e trascinare l'app in Applicazioni. La separazione degli stem
richiede Demucs, che l'app propone di installare al primo uso.

## Uso responsabile

Usa l'app **sempre nel rispetto della legge**. La musica è protetta dal
diritto d'autore anche quando passa dall'audio di sistema o da
un'interfaccia: **non catturare contenuti musicali protetti da
copyright** senza averne il diritto — registra materiale tuo o per cui
hai l'autorizzazione. E **non registrare persone che non sanno di
essere registrate**.

L'autore **declina ogni responsabilità** per usi impropri o illeciti
dell'app e per qualsiasi danno o conseguenza derivante dal suo uso.

## Licenza

Il codice del progetto è distribuito con licenza [MIT](LICENSE): il
software è fornito «così com'è», **senza garanzie di alcun tipo**,
espresse o implicite, e l'uso è a esclusivo rischio di chi lo utilizza.

L'app incorpora staticamente due librerie di terze parti (dettagli e
istruzioni di ricompilazione in [`ThirdParty/`](ThirdParty/README.md)):

- **LAME 3.100** — GNU Library GPL v2
  ([testo](ThirdParty/COPYING.lame.txt));
- **aubio 0.4.9** — GNU GPL v3
  ([testo](ThirdParty/COPYING.aubio.txt)).

Includendo aubio, **il binario distribuito è nel suo complesso soggetto
ai termini della GPL v3**. Demucs è invece uno strumento esterno
(licenza MIT), installato a parte e non incorporato nell'app.
