# Curfs

App SwiftUI/SwiftData: un media player personale, per iPhone (**Curfs**) e Mac (**CurfsMac**,
stesso progetto Xcode, target separato). Importa video da Files, riconosce automaticamente
stagioni ed episodi dai nomi di cartelle/file, li organizza in Film/Serie, tiene traccia
dell'avanzamento visto, e li riproduce con AVFoundation/AVKit (Liquid Glass, tema viola scuro
immersivo; su Mac i controlli di riproduzione sono quelli nativi di AVKit, con Picture-in-Picture
flottante incluso).

> Nata come progetto personale, non è pensata per l'App Store. La versione iPhone non distribuisce
> un binario: va buildata e installata con un proprio account Apple Developer. La versione Mac ha
> anche una release `.dmg` già pronta (vedi [Releases](../../releases)) — non firmata con un
> Developer ID Apple a pagamento, quindi al primo avvio va aperta con tasto destro → Apri per
> saltare l'avviso di Gatekeeper "sviluppatore non identificato".

## Funzionalità

- **Import da Files**: riconoscimento automatico di film/serie/stagioni/episodi dai nomi di
  cartelle e file, senza bisogno di rinominare nulla a mano.
- **Libreria** con avanzamento visto, "Continua a guardare", "Riprendi" per serie.
- **Player custom** su AVPlayer/AVKit nativo (nessuna dipendenza esterna): copre mp4/mov/m4v
  (H.264/HEVC/AAC); mkv/avi vengono importati ma potrebbero non riprodursi.
- **Salta intro / titoli di coda**: riconoscimento basato sul confronto reale dei fotogrammi tra
  episodi della stessa serie (hash percettivo), non su timing/percentuali — funziona anche con
  cold open di lunghezza variabile tra un episodio e l'altro.
- **Sezione Cerca**: si collega a un server HTTP personale (nel progetto originale un Raspberry
  Pi raggiunto via Tailscale) che espone una cartella di video con elenchi di directory in JSON.
  Permette di sfogliare, aggiungere alla libreria in streaming o scaricare offline. **Nessuna
  fonte è preconfigurata**: ognuno inserisce l'URL del proprio server da Impostazioni → Cerca.
  Vedi [CLAUDE.md](CLAUDE.md#decisionigotcha-non-ovvi-dal-codice) (sezione "Sezione Cerca /
  streaming remoto") per il contratto lato server (in breve: nginx con
  `autoindex_format json;` + supporto alle richieste Range, nessun endpoint custom).

## Requisiti

- Xcode con SDK iOS 26 / macOS 26.
- iPhone/simulatore iOS **26.0+** per `Curfs`, Mac su **macOS 26+** per `CurfsMac` (le API Liquid
  Glass usate — `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)` —
  richiedono la versione 26 su entrambe le piattaforme).
- Un account Apple Developer (anche gratuito) per firmare la build: apri il progetto, in
  **Signing & Capabilities** seleziona il tuo team per ciascun target (il repo non include un
  team ID). Su iPhone, con un account gratuito l'app installata scade dopo 7 giorni e va
  reinstallata; su Mac non c'è questo limite.

## Build

```
# iPhone
xcodebuild -project Curfs.xcodeproj -scheme Curfs -destination 'id=<simulator-id>' build

# Mac
xcodebuild -project Curfs.xcodeproj -scheme CurfsMac -destination 'platform=macOS' build
```

Fidati solo dell'esito di `xcodebuild` (`** BUILD SUCCEEDED **`): l'indice di SourceKit in Xcode
mostra spesso diagnostiche fasulle/stale su questo progetto anche su build reali pulite.

## Architettura

Panoramica rapida, dettagli e decisioni non ovvie in [CLAUDE.md](CLAUDE.md):

- `Models/` — modelli SwiftData (`MediaItem`, `ShowSummary`).
- `Support/` — import, storage, miniature, riconoscimento intro/titoli di coda.
- `Player/` — player custom iPhone (touch) e relativa logica/gesture/orientamento; la logica di
  stato (`PlayerViewModel`) è condivisa anche col player Mac.
- `Remote/` — sezione Cerca/streaming da server remoto e download offline.
- `Views/` — schermate libreria, card, sezione Cerca (condivise tra i due target).
- `Utilities/` — helper UI condivisi.
- `CurfsMac/` — target Mac: entry point e player nativo AVKit (controlli, fullscreen e
  Picture-in-Picture già pronti). Riusa Models/Support/Remote/Views/Utilities as-is.

## Bug noto

Su alcuni dispositivi/simulatori, dentro le `ScrollView` di `LibraryHomeView`/`SearchView`/
`ShowDetailView`, le card possono perdere il margine sinistro e finire a filo del bordo dello
schermo. Isolato con un repro minimo (non è la griglia, non è il tipo di bottone, non è il
valore del padding) ma la causa non è confermata — sospetto un bug di SwiftUI/iOS 26 in
`ScrollView` + `VStack` con figli di larghezza eterogenea. Dettagli, repro e tentativi già
esclusi in [CLAUDE.md](CLAUDE.md). PR benvenute.

## Non ancora implementato

Picture-in-Picture su iPhone (su Mac c'è già, nativo di AVKit), layout dedicato iPad, sync
iCloud, icona Mac disegnata a mano (quella attuale è generata per ricomposizione dell'icona
iOS). Nella sezione Cerca: poster/metadati (ora solo placeholder a icona), pull-to-refresh del
catalogo remoto, riconciliazione tra un episodio guardato in streaming e lo stesso poi scaricato
offline.

## Licenza

[MIT](LICENSE) © M-Tre Consulting
