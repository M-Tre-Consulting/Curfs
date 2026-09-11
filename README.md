# Curfs

App iOS in SwiftUI/SwiftData: un media player personale. Importa video da Files, riconosce
automaticamente stagioni ed episodi dai nomi di cartelle/file, li organizza in Film/Serie, tiene
traccia dell'avanzamento visto, e li riproduce con un player custom basato su AVPlayer (Liquid
Glass, tema viola scuro immersivo).

> Nata come progetto personale per un singolo iPhone, non è pensata per l'App Store e non
> distribuisce alcun binario: ognuno la builda e la installa sul proprio dispositivo con il
> proprio account Apple Developer.

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

- Xcode con SDK iOS 26.
- Dispositivo o simulatore iOS **26.0+** (le API Liquid Glass usate — `.glassEffect`,
  `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)` — richiedono iOS 26).
- Un account Apple Developer (anche gratuito) per firmare la build: apri il progetto, in
  **Signing & Capabilities** seleziona il tuo team (il repo non include un team ID). Con un
  account gratuito l'app installata scade dopo 7 giorni e va reinstallata.

## Build

```
xcodebuild -project Curfs.xcodeproj -scheme Curfs -destination 'id=<simulator-id>' build
```

Fidati solo dell'esito di `xcodebuild` (`** BUILD SUCCEEDED **`): l'indice di SourceKit in Xcode
mostra spesso diagnostiche fasulle/stale su questo progetto anche su build reali pulite.

## Architettura

Panoramica rapida, dettagli e decisioni non ovvie in [CLAUDE.md](CLAUDE.md):

- `Models/` — modelli SwiftData (`MediaItem`, `ShowSummary`).
- `Support/` — import, storage, miniature, riconoscimento intro/titoli di coda.
- `Player/` — player custom e relativa logica/gesture/orientamento.
- `Remote/` — sezione Cerca/streaming da server remoto e download offline.
- `Views/` — schermate libreria, card, sezione Cerca.
- `Utilities/` — helper UI condivisi.

## Bug noto

Su alcuni dispositivi/simulatori, dentro le `ScrollView` di `LibraryHomeView`/`SearchView`/
`ShowDetailView`, le card possono perdere il margine sinistro e finire a filo del bordo dello
schermo. Isolato con un repro minimo (non è la griglia, non è il tipo di bottone, non è il
valore del padding) ma la causa non è confermata — sospetto un bug di SwiftUI/iOS 26 in
`ScrollView` + `VStack` con figli di larghezza eterogenea. Dettagli, repro e tentativi già
esclusi in [CLAUDE.md](CLAUDE.md). PR benvenute.

## Non ancora implementato

Picture-in-Picture, layout dedicato iPad, sync iCloud. Nella sezione Cerca: poster/metadati (ora
solo placeholder a icona), pull-to-refresh del catalogo remoto, riconciliazione tra un episodio
guardato in streaming e lo stesso poi scaricato offline.

## Licenza

[MIT](LICENSE) © M-Tre Consulting
