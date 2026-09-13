# Curfs

App SwiftUI/SwiftData: media player personale (solo per i dispositivi del proprietario, non
destinata all'App Store), con due target nello stesso progetto Xcode — **Curfs** per iPhone e
**CurfsMac** per Mac (vedi sezione dedicata più sotto). Importa video da Files, riconosce
automaticamente stagioni/episodi dai nomi di cartelle/file, li organizza in Film/Serie, tiene
traccia dell'avanzamento, e li riproduce con AVFoundation/AVKit (Liquid Glass, tema viola scuro
immersivo; su Mac il player usa i controlli nativi di AVKit invece del player custom touch).

**Ex nome:** il progetto si chiamava "Mediapple", rinominato in "Curfs" il 2026-08-20 (cartella,
progetto Xcode, target, scheme, tipi Swift). Il **bundle identifier è rimasto**
`com.nicoloperri.Mediapple` di proposito, per non perdere libreria/progressi/cache già presenti
sul dispositivo reale al prossimo reinstall (iOS tratterebbe un bundle ID diverso come app nuova).

## Vincoli

- iPhone reale del proprietario su **iOS 26.6**. Deployment target `IPHONEOS_DEPLOYMENT_TARGET =
  26.0` — necessario per le API Liquid Glass (`.glassEffect`, `GlassEffectContainer`,
  `.buttonStyle(.glass/.glassProminent)`). Non abbassarlo se si toccano quei file.
- Motore di riproduzione: **solo AVFoundation/AVKit nativo**, nessuna dipendenza esterna. Copre
  mp4/mov/m4v (H.264/HEVC/AAC). mkv/avi vengono importati ma potrebbero non riprodursi.
- Provisioning gratuito: l'app installata scade dopo 7 giorni senza account Developer a pagamento.
- Build/verifica rapida da terminale:
  `xcodebuild -project Curfs.xcodeproj -scheme Curfs -destination 'id=<simulator-id>' build`.
  **SourceKit mostra spesso diagnostiche fasulle e stale** ("Cannot find type X in scope",
  "unable to type-check in reasonable time") anche su build reali pulite: fidarsi solo
  dell'esito di `xcodebuild` (`** BUILD SUCCEEDED **`), non dell'indice dell'editor.

## Architettura

- `Models/` — `MediaItem` (SwiftData model: film o episodio, progresso, flag finito, ecc.),
  `ShowSummary` (raggruppamento non persistito degli episodi di una serie, calcolato al volo).
- `Support/` — import (`ImportEngine`, `ImportViewModel`, `FileNameParser`), storage
  (`LibraryStorage`, `LibraryMaintenance`), miniature (`ThumbnailGenerator`), e il riconoscimento
  di intro/titoli di coda (`FrameHasher`, `EpisodeFingerprint`, `FingerprintExtractor`,
  `FingerprintStorage`, `IntroCreditsAnalyzer`).
- `Player/` — `PlayerView` + `PlayerViewModel` (stato/logica), `PlayerControlsOverlay`,
  `PlayerGestureZones`, `OrientationController` + `AppDelegate` (rotazione forzata),
  `SkipIntroButton`, `NextEpisodePromptView`, `VideoPlayerLayerView`.
- `Remote/` — sezione Cerca / streaming da server remoto: `RemoteContentProvider` (protocollo +
  registry), `HTTPTreeProvider` (implementazione per server HTTP statico con elenchi JSON),
  `RemoteSourceConfig`/`RemoteSourceStore` (config persistita), `RemoteDownloadManager` (download
  offline).
- `Views/` — schermate libreria (`LibraryHomeView`, `ShowDetailView`), card (`ShowCardView`,
  `MovieCardView`, `ContinueWatchingCard`, `EpisodeRowView`) e `Views/Search/` (`SearchView`,
  `SearchResultCard`, `RemoteTitleDetailView`, `RemoteSourceSettingsView`, `DownloadsOverlay`).
- `Utilities/` — `AppBackground`, `ProgressLineView`, `PressableButtonStyle`, `ThumbnailImageView`,
  `TimeFormatter`, `CardGrid` (colonne delle griglie di card).

## App macOS (CurfsMac)

Secondo target nello stesso `Curfs.xcodeproj` (scheme `CurfsMac`), aggiunto il 2026-09-11: stessa
libreria/import/Cerca, ma pensata per Mac invece che riadattata da iPhone — niente rotazione,
player con i controlli nativi di AVKit invece del player custom touch. Solo per uso locale
dell'utente (non firmata per distribuzione, vedi sotto), build via
`xcodebuild -project Curfs.xcodeproj -scheme CurfsMac -destination 'platform=macOS' build`.

- **Come condivide il codice**: il progetto usa i "file system synchronized groups" di Xcode 16+
  (`PBXFileSystemSynchronizedRootGroup`) — non ci sono `PBXBuildFile`/`PBXFileReference` per
  ogni file, la cartella `Curfs/` è un unico gruppo sincronizzato collegato a **entrambi** i
  target. Un file aggiunto dentro `Curfs/` appartiene quindi automaticamente anche a `CurfsMac`,
  **a meno che non sia nella lista di eccezioni** (`PBXFileSystemSynchronizedBuildFileExceptionSet`
  nel `.pbxproj`, targettizzata su `CurfsMac`) che esclude i file iOS-only: `CurfsApp.swift`,
  `Player/AppDelegate.swift`, `Player/OrientationController.swift`,
  `Player/VideoPlayerLayerView.swift`, `Player/PlayerView.swift`,
  `Player/PlayerControlsOverlay.swift`, `Player/PlayerGestureZones.swift`. La cartella `CurfsMac/`
  è un secondo gruppo sincronizzato, collegato solo al target Mac.
  ⚠️ **Il gem Ruby `xcodeproj` non fa il round-trip pulito di questo formato** (un salvataggio
  senza modifiche ha già perso `validationLevel` e alterato dei commenti in un test) — il target
  è stato aggiunto editando `project.pbxproj` a mano (testato prima su una copia con
  `xcodebuild -list`/`build` prima di applicarlo al progetto vero). Per touccare di nuovo la
  struttura del progetto (nuovi target, ecc.): a mano o da Xcode stesso, non con quel gem.
- **Player Mac**: `CurfsMac/Player/MacVideoPlayerView.swift` (`NSViewRepresentable` su
  `AVPlayerView`) + `MacPlayerView.swift`, invece di `VideoPlayerLayerView`/
  `PlayerControlsOverlay`/`PlayerGestureZones`. Scelta deliberata: `AVPlayerView` dà scrubber,
  fullscreen e **Picture-in-Picture flottante/ridimensionabile già pronti** — esattamente quello
  che serviva ("mettere il video dove si vuole, ridimensionarlo") senza ricostruirlo a mano.
  `PlayerViewModel` resta **condiviso** (progresso, salta-intro, prossimo episodio): solo
  `toggleOrientation()`/`resetOrientation()` e `activate/deactivateAudioSession()` sono dentro
  `#if os(iOS)` (rotazione e `AVAudioSession` non esistono su macOS).
- **Fix cross-platform emersi buildando il target Mac** (bug latenti anche per iOS, non solo
  differenze di piattaforma):
  - `ThumbnailGenerator`/`ThumbnailImageView` usavano `UIImage` — riscritti su `CGImage`/ImageIO
    (`CGImageDestination`/`CGImageSourceCreateWithURL`), cross-platform, stessa resa visiva.
  - `Color(.secondarySystemBackground)` (basato su `UIColor`, non esiste su Mac) → RGB espliciti.
  - `PressableButtonStyle` viveva dentro `Player/PlayerControlsOverlay.swift` (file iOS-only,
    escluso dal target Mac) ma era usata da `LibraryHomeView`/`SearchView`: build Mac falliva con
    "cannot find PressableButtonStyle in scope". Spostata in `Utilities/` dove appartiene
    davvero.
  - `.topBarTrailing` → `.primaryAction` (cross-platform), `.navigationBarTitleDisplayMode`/
    `.searchable(placement: .navigationBarDrawer)`/`.keyboardType`/`.textInputAutocapitalization`
    dentro `#if os(iOS)` (non esistono su Mac). `.fullScreenCover` (solo iOS) → `#if os(iOS)
    fullScreenCover #else sheet #endif` nei 3 punti che aprono il player
    (`LibraryHomeView`/`ShowDetailView`/`RemoteTitleDetailView`).
  - ⚠️ **`Menu` con `Button` che mutano uno `@State` che ridisegna lo stesso `Menu`**: su macOS
    l'NSMenu può restare bloccato aperto (non capita su iOS, dove UIKit gestisce i menu
    diversamente) — capitato con "Salva in:" in `RemoteTitleDetailView`. Mitigato rimandando
    l'assegnazione allo `@State` con `Task { @MainActor in ... }` dentro l'azione del `Button`
    invece di farla sincrona. Come rete di sicurezza aggiuntiva (il pannello di dettaglio è
    presentato come sheet, e la sola "Chiudi" in toolbar su Mac non era un'uscita abbastanza
    affidabile/visibile), `RemoteTitleDetailView` ha anche una X separata sempre visibile in alto
    a destra (`#if os(macOS)`, `.overlay(alignment: .topTrailing)`) indipendente dalla toolbar.
- **Icona**: l'asset catalog `AppIcon.appiconset` (condiviso) aveva già gli slot idiom "mac"
  (16→512, @1x/@2x) ma vuoti. Popolati da `icon-any.png` (quello iOS, quadrato pieno) ricomposto
  in stile Big Sur — margine, angoli arrotondati, ombra morbida — con uno script CoreGraphics
  ad hoc (non con Icon Composer), poi ridimensionato via `sips`.
- **Bundle ID separato**: `com.nicoloperri.CurfsMac` (a differenza di quello iOS, qui non serve
  continuità dati con nessuna installazione precedente).
- **Non sandboxata** (`ENABLE_APP_SANDBOX = NO`): come una normale app Mac, accesso libero a
  file/rete per import e sezione Cerca — non essendo per l'App Store non serve la sandbox né le
  entitlement che richiederebbe. Firma automatica con lo stesso team Apple dell'app iOS (development,
  non Developer ID): funziona senza problemi sul Mac dell'utente, ma un `.dmg` distribuito ad
  altri farà comparire l'avviso Gatekeeper "sviluppatore non identificato" (serve tasto destro →
  Apri la prima volta) — non essendoci un account Developer a pagamento non è evitabile.
- **Download remoti**: `RemoteDownloadManager` (condiviso) funziona finché l'app Mac è aperta, ma
  non ha l'aggancio equivalente di `AppDelegate.application(_:handleEventsForBackgroundURLSession:)`
  usato su iOS per il risveglio da app terminata — concetto che su Mac non si applica allo stesso
  modo (l'app non viene sospesa/terminata dal sistema come su iOS).

## Decisioni/gotcha non ovvi dal codice

- **Griglie di card responsive**: `LibraryHomeView` / `SearchView` NON usano
  `GridItem(.adaptive(...))` — a larghezze piccole (12 mini / SE, Display Zoom, Dynamic Type
  grande) l'adaptive sceglieva una colonna troppo larga e le card sforavano lo schermo. La
  larghezza va letta da un `GeometryReader` esterno che avvolge l'intera `ScrollView` (non da
  `.onGeometryChange` sulla griglia stessa — quella strada, usata in un primo tentativo, ha un suo
  problema separato, vedi sotto), passata a `CardGrid.columns(forWidth:)`, che restituisce un
  numero intero di colonne `.flexible` (minimo 2): queste NON possono eccedere lo spazio
  disponibile, è garantito dal layout system.
- ⚠️ **Bug reale non risolto, isolato ma non capito**: su dispositivo reale (iPhone 12 mini,
  iOS 26.1.2) — e riprodotto anche in simulatore, su più device/runtime diversi, con dati veri E
  con repro minimi — card e testo dentro le `ScrollView` di `LibraryHomeView`/`SearchView`/
  `ShowDetailView` a volte perdono il margine sinistro e finiscono a filo del bordo vero dello
  schermo. **NON è**: la griglia/`CardGrid` (riprodotto anche con `ContinueWatchingCard`, fuori
  da ogni griglia), il tipo di bottone (riprodotto identico con `Button`, `.buttonStyle(.plain)`,
  `PressableButtonStyle`, e con `.onTapGesture` senza alcun bottone), il valore del padding
  (riprodotto da 16pt fino a testato-funzionante-a-100pt), `.padding()` vs `.safeAreaPadding()`
  (entrambi falliscono nello stesso modo), `GeometryReader` (riprodotto sia con sia senza),
  `.frame(maxWidth: .infinity)` vs `.frame(width:)` esplicito (entrambi falliscono). **Isolato
  con certezza** (repro minimo, ripetibile): dentro una `ScrollView`, una `VStack(alignment: .leading)`
  con **un solo figlio** a larghezza fissa (`.frame(width:)`) si posiziona bene; **appena la
  VStack ha un secondo figlio qualsiasi** (anche solo un `Text`, anche solo un'altra card
  identica) — il figlio a larghezza fissa (in certi casi anche il primo) finisce a filo bordo.
  Non un frame di transizione: persiste da fermo, a freddo, su installazioni pulite. Tentativi
  che NON hanno risolto: `.safeAreaPadding` unico sulla ScrollView invece di `.padding()` sparsi,
  `.frame(maxWidth: .infinity, alignment: .leading)` esplicito sul contenitore, avvolgere la card
  in `HStack { card; Spacer() }` invece di affidarsi all'allineamento della VStack. Sospetto: un
  bug genuino di SwiftUI/iOS 26 nell'interazione `ScrollView` + `VStack` con figli di larghezza
  eterogenea, non qualcosa di sbagliato nel nostro codice — ma non confermato. Se si riprende
  questa indagine: NON ripartire dalle stesse ipotesi (grid/bottoni/valore padding, già escluse
  con certezza), e considerare `List` o un layout manuale via `GeometryReader` per-riga come
  alternative strutturali invece di inseguire ancora `VStack`+`ScrollView`. Le card di griglia
  (`ShowCardView`, `MovieCardView`, `SearchResultCard`) usano `.aspectRatio(_, contentMode: .fit)`
  + `.frame(maxWidth: .infinity)` per non spingersi oltre la colonna; dove la miniatura ha già un
  frame fisso (`EpisodeRowView`, header di `ShowDetailView`) resta `.fill` (è comunque limitata).

- **`LibraryStorage.thumbnailsDirectory` è in Application Support, NON in Caches**: un
  aggiornamento di iOS (26.1.2) ha svuotato `Caches/` sul dispositivo reale e le miniature degli
  episodi scaricati sono sparite (card grigie) — comportamento di sistema documentato, non un bug
  del codice: iOS può ripulire Caches quando vuole. I video restano al sicuro in
  `mediaDirectory` (Documents), le miniature no se stanno in Caches. `ThumbnailImageView` inoltre
  si rigenera da sola al volo se il file manca (chiama `ThumbnailGenerator.generateIfNeeded`),
  quindi qualunque perdita futura si ripara da sé aprendo la libreria, senza bisogno di un tasto
  manuale. `fingerprintsDirectory` (impronte/risultati sigla-coda) resta invece in Caches
  DI PROPOSITO: quel sistema è già progettato per ricalcolarsi da solo in background con
  indicatore di stato visibile (vedi sezione sigla/coda) se la cache manca, quindi lì Caches va
  bene com'è.

- **Liquid Glass non anima la propria rimozione** se una view viene tolta dall'albero con
  `if condition { view }.transition(...)` — sparisce di scatto. Soluzione: tenere la view sempre
  montata e animare proprietà semplici (`.opacity`, `.scaleEffect`, `.blur(radius:)`), che
  funzionano in entrambe le direzioni sotto la stessa `withAnimation`. Vedi `PlayerView.body`
  per `PlayerControlsOverlay` **e** per `NextEpisodePromptView` (stessa regola applicata dopo:
  prima era `if vm.showNextEpisodePrompt { NextEpisodePromptView(...) }.transition(...)`,
  spariva di scatto invece di sfumare all'"Annulla"; ora è sempre montata, `next` è opzionale, e
  il countdown/reset è guidato da `isPresented` via `.onChange` invece che da `.onAppear`/
  `.onDisappear` — che con la view sempre montata scatterebbero una volta sola in assoluto).
- **Doppio tap per skip ±10s** (`PlayerGestureZones`, zone sinistra/destra + zona centrale per
  mostra/nascondi controlli): il timestamp dell'ultimo tap va aggiornato a `now` dopo ogni salto
  registrato, MAI azzerato a `nil` — azzerarlo (bug reale, corretto) faceva sì che un terzo tap
  ravvicinato fosse trattato come "primo tap di una sequenza nuova" (mostra/nasconde i controlli)
  invece di continuare la sequenza di salti: con tap rapidi ripetuti si alternava
  salto/mostra-nascondi invece di accumulare i salti come da doc in cima al file.
- **Rotazione persistente**: senza un `AppDelegate` con `supportedInterfaceOrientationsFor:`,
  un'app SwiftUI-lifecycle pura perde l'orientamento richiesto esplicitamente ogni volta che la
  scena torna attiva dal background (ricade sul default di Info.plist = verticale). Fix:
  `OrientationController.currentMask` come unica fonte di verità, letta da `AppDelegate`; più un
  riallineamento di sicurezza in `PlayerView.onChange(of: scenePhase)`. Il passaggio all'episodio
  successivo (`playNext`) non deve resettare l'orientamento: `PlayerViewModel.stop(resetOrientation:)`.
- **Riconoscimento intro/titoli di coda**: NON basato su timing/percentuali (esplicitamente
  rifiutato dall'utente come inaffidabile). Confronta fotogrammi reali tra episodi della stessa
  serie via hash percettivo (dHash) + ricerca dello sfalsamento temporale migliore, poi cerca il
  tratto continuo in comune. I fotogrammi quasi uniformi (nero/dissolvenze) vengono scartati in
  `FrameHasher` perché producono falsi positivi tra episodi diversi — causa reale di uno skip
  mal posizionato in passato. Serve consenso tra almeno 2 episodi confrontati (`IntroCreditsAnalyzer.consensus`)
  prima di mostrare il pulsante; con overlap poco chiaro tra episodi non mostra nulla piuttosto
  che indovinare. Dettagli non ovvi:
  - Finestra iniziale **ampia** (fino a 8 min, `maxIntroWindow`/`maxShift` = 480; era 300/5 min,
    alzata dopo un pilot reale con cold open di 7:15 che ci cadeva fuori) campionata a
    1,5 s (`FingerprintExtractor`, API batch `images(for:)`); finestra coda campionata larga
    (2 s). La finestra ampia è indispensabile per il **primo episodio** di una serie: spesso
    ha un cold open lungo e la sigla parte minuti dopo che negli altri episodi — con finestra
    stretta o `maxShift` piccolo l'ep. 1 non veniva mai rilevato. Il bordo del tratto è esteso
    di un passo così il salto atterra appena *dentro* l'episodio.
  - Due cache su disco: `FingerprintStorage` (impronte per episodio, `cacheVersion` bump-abile) e
    `IntroCreditsStorage` (il *risultato* dell'analisi per episodio, legato a `analysisVersion` +
    durata + firma dei vicini usati). La seconda rende il "salta intro" deterministico e immediato
    dalla seconda visione, invece di riconfrontarsi ogni volta coi vicini del momento.
  - **Pre-calcolo prima del play** (`IntroCreditsAnalyzer.shared.warm`): all'avvio dell'app
    (`IntroCreditsWarmup` da `RootTabView.task`) l'analisi di TUTTA la libreria locale viene
    calcolata e messa in cache in background (più recente per primo); così anche dopo — dopo
    l'import (`ImportViewModel`) e all'apertura di `ShowDetailView`. `PlayerViewModel.prewarmNextEpisode()`
    fa lo stesso per l'episodio successivo nel binge. Il player usa un'istanza propria
    dell'analizzatore, i warmer usano `.shared`. `isInIntro` ha 5 s di anticipo sul bordo.
    Lista vicini condivisa via `PlayerViewModel.siblingEpisodes(of:in:)`.
  - **Dipende dalla durata reale dell'episodio**: `analyze` esce (senza cache) se `duration < 90`
    — tipico subito dopo l'import, prima che `MediaDurationMeasurer`/`PlayerViewModel.resolveDuration`
    la misurino. `PlayerViewModel.onDurationResolved()` rilancia l'analisi una volta appena la
    durata è nota, così il pulsante compare anche alla PRIMA riproduzione di un episodio appena
    importato invece che solo dalla seconda.
  - **Indicatore di stato** (`IntroAnalysisStatus`, `@Observable`): in `ShowDetailView` mostra
    un progresso "Analisi sigla… N/M" mentre l'app calcola. Aggiornato da tutti i punti di warm;
    solo informativo, non tocca la logica. `IntroCreditsAnalyzer.cacheStatus(for:siblings:)` è la
    lettura di sola cache usata per popolarlo senza ricalcolare (`.missing` / `.readyNoIntro` /
    `.readyWithIntro`). **"Pronto" (cache valida) ≠ "sigla trovata"**: un episodio può essere
    analizzato con successo (niente da ricalcolare) SENZA che sia stato trovato un tratto in
    comune coi vicini — es. un solo vicino disponibile e nessun consenso, o davvero nessuna sigla
    condivisa. `IntroAnalysisStatus` tiene `ready` e `readyWithIntro` distinti apposta; l'indicatore
    mostra "Salta intro pronto" ✓ solo se `withIntro` conta gli episodi con sigla davvero trovata,
    "Nessuna sigla riconosciuta per questa stagione" se `ready == total` ma `withIntro == 0`. Prima
    di questa distinzione "pronto" ✓ compariva anche per stagioni senza alcuna sigla rilevata —
    sembrava un bug ("dice pronto ma non c'è il pulsante") quando in realtà l'analisi aveva
    semplicemente concluso "niente da saltare qui".
  - **Mai in streaming**: `siblingEpisodes` è popolato solo per item locali (confronterebbe
    fotogrammi di ogni episodio via rete).
  - **Tasto manuale "Ricalcola"** (icona ⟲ accanto all'indicatore in `ShowDetailView`): svuota
    `IntroCreditsAnalyzer.resetDiskCache()` (cancella tutti i file in
    `LibraryStorage.fingerprintsDirectory`, sia impronte che risultati, per l'intera libreria) +
    `IntroAnalysisStatus.shared.resetAll()`, poi incrementa `introCacheResetTick` che cambia
    l'id del `.task` di warmup così SwiftUI cancella quello in corso e ne riparte uno da zero.
    Il sistema si autoripara già da solo (fingerprint/risultato mancante ⇒ si ricalcola alla
    prossima occasione), ma un modo per forzarlo SUBITO senza aspettare i warmer in background
    resta utile quando l'utente non si fida del risultato mostrato.
- **"Continua a guardare"** in home mostra un solo item (l'ultimo in assoluto per
  `lastPlayedAt`), non tutti i video a metà. Dentro una serie, "Riprendi"
  (`ShowSummary.nextToWatch`) punta all'ultimo episodio *di quella serie* effettivamente lasciato
  a metà (per `lastPlayedAt`), non al primo non finito in ordine numerico.
- **Eliminazione libreria**: esistono già eliminazione per singolo episodio/film (context menu),
  intera serie (context menu in home) e singola stagione (tasto cestino in `ShowDetailView`,
  tramite `LibraryMaintenance.deleteSeason`). I file vengono copiati nel sandbox dell'app
  all'import: cancellare la sorgente originale non li tocca, vanno eliminati dall'app stessa.
- **Sezione "Cerca" / streaming remoto** (`Remote/`, `Views/Search/`): si collega a un server
  HTTP statico dell'utente (Raspberry Pi via Tailscale) che espone una cartella di video con
  elenchi di directory in JSON (nginx `autoindex_format json`). Decisioni non ovvie:
  - **Nessun endpoint speciale lato server**: `HTTPTreeProvider` cammina l'albero delle
    directory e riusa `FileNameParser` (le stesse euristiche dell'import da Files) per
    ricostruire film/serie/stagioni/episodi. Il contratto lato server è solo: elenchi JSON +
    supporto alle richieste Range sui file. Catalogo calcolato una volta e tenuto in memoria
    per la vita del provider (ricreato solo al cambio di `RemoteSourceConfig`).
  - **Config in `RemoteSourceStore`** (UserDefaults, non Keychain: app personale monodispositivo).
    Salvandola si emette `.remoteSourceConfigChanged`, che fa ricostruire il provider in `SearchView`.
    Il provider si costruisce sempre da `RemoteContentProviderRegistry.makeProvider(config:)`.
  - **Streaming vs download**: `AVPlayer` legge l'URL remoto direttamente (richieste Range), con
    gli header di auth passati via `AVURLAssetHTTPHeaderFieldsKey` (vedi `PlayerViewModel.makePlayer`).
    Il download offline (`RemoteDownloadManager`) resta come opzione secondaria e usa lo stesso URL.
  - **Download offline = URLSession di background** (`BackgroundDownloadEngine` dentro
    `RemoteDownloadManager.swift`): singleton, sessione legata a `com.nicoloperri.Mediapple.downloads`,
    `sessionSendsLaunchEvents = true`. Prosegue con l'app sospesa e in caso di interruzione
    (app chiusa, rete caduta) riprende da `resumeData` invece che da zero, con ritenta
    automatica (backoff 1/2/4/8 s) e pulsante "riprendi" manuale nel `DownloadsOverlay`
    (nuovo stato `.paused`). Il registro dei download vive in
    `Application Support/Downloads/records.json` (+ `<id>.resume`, `staging/<id>`) così
    sopravvive alla chiusura. `AppDelegate.application(_:handleEventsForBackgroundURLSession:)`
    gira il completion handler di sistema a `RemoteDownloadManager.shared`. La finalizzazione
    (staging → libreria + `MediaItem`) può avvenire dopo un rilancio headless: per questo il
    `MediaItem` si crea su `ModelContext(AppModelContainer.shared)` — **container SwiftData
    unico condiviso** con la scena (`CurfsApp` usa `.modelContainer(AppModelContainer.shared)`),
    non più `.modelContainer(for:)`. `RemoteDownloadManager()` non è più istanziabile:
    usare `.shared`.
  - **`MediaItem.remoteURLString`**: se valorizzato l'item è in streaming (nessun file locale,
    `relativePath` vuoto, `playbackURL` punta al remoto). Attributo opzionale ⇒ migrazione
    SwiftData automatica. Gli item remoti **compaiono nelle griglie** Serie TV / Film come
    quelli locali (badge `StreamingBadge`): se lo stesso episodio/film esiste sia locale sia
    streaming, `ShowSummary.groups` / `LibraryHomeView.movies` tengono il locale e nascondono
    il doppione remoto. `LibraryMaintenance.delete` e `ThumbnailGenerator` saltano il
    filesystem per questi item.
  - **Persistenza lazy**: guardando in streaming senza "aggiungere", l'item viene inserito in
    SwiftData al primo avanzamento reale (`PlayerViewModel.persistProgress`, item ancora senza
    `modelContext`) e da lì compare in "Continua a guardare" e in griglia.
  - **Aggiungi alla libreria (streaming)** (`RemoteTitleDetailView.addSeasonToLibrary` /
    `addMovieToLibrary`): inserisce voci `MediaItem` remote per l'intera stagione / il film
    **senza scaricare**. È l'azione primaria; il download offline via `RemoteDownloadManager`
    (`downloadSeason` / `downloadMovie`) è l'alternativa secondaria.
  - **Serie di destinazione** (menu "Salva in:"): `effectiveShowName` = target scelto tra le
    serie locali già presenti, oppure il nome remoto per una serie nuova. Serve perché il nome
    remoto "prettificato" (`il-trono-di-spade` → `Il Trono Di Spade`, vedi
    `HTTPTreeProvider.prettify`) spesso non coincide col nome della serie locale importata.
    Usato da tutti i salvataggi (stagione/episodio, streaming o download).
  - **Tab Cerca**: all'apertura carica e mostra tutto il catalogo (`search(query: "")`), la
    barra filtra soltanto. Pull-to-refresh ricostruisce il provider (invalida la cache).
  - Il selettore stagione compare solo con >1 stagione; con una sola stagione si mostra
    comunque l'etichetta "Stagione N · M episodi".
  - **Niente riconoscimento sigla/coda in streaming**: confronterebbe fotogrammi di ogni
    episodio via rete. `PlayerViewModel` popola `siblingEpisodes` solo per item locali.
  - Setup Pi: nginx statico su `/mnt/nextcloud_data/SC` con `autoindex_format json` +
    `tailscale serve --https=443`; l'app usa l'URL `*.ts.net` (cert valido ⇒ niente eccezioni ATS).
  - **Locandine ufficiali per film/serie remote** (`Remote/PosterFetcher.swift`): il server del
    Pi non ha metadati, solo file — `HTTPTreeProvider.buildCatalog` valorizza
    `RemoteTitle.posterURL` (già consumato da `SearchResultCard`/`RemoteTitleDetailView` via
    `AsyncImage`, mancava solo chi lo popolasse) interrogando l'**API di ricerca di iTunes**
    (`itunes.apple.com/search`), pubblica e senza chiave/account. ⚠️ **`media=movie` come
    parametro di query restituisce sistematicamente 0 risultati** (comportamento osservato, non
    documentato/garantito da Apple, potrebbe cambiare) — la ricerca va fatta senza filtro
    `media`/`entity` e il tipo giusto (film vs serie) selezionato lato client dal campo `kind` di
    ogni risultato (`feature-movie` / `tv-episode` / `tv-season`). L'artwork di default è
    100×100: l'URL viene ringrandito sostituendo `100x100bb` con `600x900bb` nel path. Risultati
    (trovati E non trovati, per non riprovare titoli assenti da iTunes ad ogni ricostruzione del
    catalogo) tenuti in cache in `Caches/RemotePosters.json` — non Application Support: perderla
    non è un problema, si ricalcola da sola (stesso ragionamento di `fingerprintsDirectory`).
    Risolte a piccoli gruppi concorrenti (6 alla volta) durante la costruzione del catalogo, non
    tutte insieme: eviti di sparare decine di richieste in parallelo per una libreria grande.
    ⚠️ **`AsyncImage` in una griglia a righe di altezza libera (`LazyVGrid`) sfora lo schermo**
    se non gli dai una dimensione esplicita: senza, propone come "ideale" le dimensioni reali
    dell'immagine scaricata (es. 600×900pt della locandina) invece di quelle della cella che la
    ospita — un `.aspectRatio(_, contentMode: .fit)` esterno da solo non basta a contenerla
    (capitato in `SearchResultCard`, il vecchio placeholder `Rectangle` non ne soffriva perché non
    ha una dimensione "naturale" propria). Fix/pattern riusabile: `Utilities/RemotePosterImage.swift`
    avvolge il contenuto in un `GeometryReader` e forza `.frame(width:proxy.size.width,
    height:proxy.size.height)` — nessuna dimensione naturale propria, si comporta come il
    placeholder. Dove il contenitore ha già un `.frame(height:)` esplicito (es. l'header a 200pt
    di `RemoteTitleDetailView`/`ShowDetailView`) il problema non si presenta comunque.
    `RemotePosterImage` è anche il punto da cui `ShowCardView`/`MovieCardView`/
    `ShowDetailView.posterBanner` mostrano la locandina (2:3, invece del frame video 16:9) per un
    titolo che viene dal catalogo remoto. ⚠️ **Sta su `MediaItem.isRemoteOrigin`/
    `ShowSummary.hasRemoteOrigin`, non su `isRemote`/`isStreaming`**: la prima versione usava
    `isStreaming` (tutti gli episodi ancora in streaming) e la copertina tornava al frame video
    non appena si scaricava anche un solo episodio — sbagliato, la locandina va tenuta per sempre
    una volta che il titolo è stato aggiunto da Cerca, scaricato o no. `MediaItem.remoteOriginFlag`
    (opzionale ⇒ migrazione automatica) esiste apposta: `RemoteDownloadManager.finalize` crea per
    ogni download un `MediaItem` **locale nuovo e separato** (non converte quello in streaming), e
    quello nuovo lo marca `remoteOrigin: true` così l'origine sopravvive anche quando `isRemote`
    torna false. Per gli item creati già `isRemote` (streaming, mai scaricati) non serve
    valorizzarlo esplicitamente: `isRemoteOrigin` ricade su `remoteOriginFlag ?? isRemote`. Il
    badge "in streaming" invece resta legato a `isRemote`/`isStreaming` come prima (ha senso solo
    finché serve davvero la rete per guardarlo). Per gli episodi/film scaricati PRIMA che
    `remoteOriginFlag` esistesse (a quella data `RemoteDownloadManager.finalize` creava un
    `MediaItem` locale indistinguibile da un import da Files, nessun modo di saperlo col senno di
    poi) — tasto **"Ripara copertine scaricate"** in `RemoteSourceSettingsView`
    (`LibraryMaintenance.backfillRemoteOrigin`): interroga il catalogo del server e marca
    retroattivamente gli item locali il cui showName/title combacia con un titolo del catalogo.
    Best-effort per nome, non per ID: un episodio salvato sotto un nome di serie diverso da quello
    del Pi (vedi "Salva in:"/`effectiveShowName`) non viene riconosciuto.
  - **Miniature reali per episodi/film remoti**: `ThumbnailGenerator` (condiviso con l'import
    locale) prima si fermava subito per gli item `isRemote` (niente file locale ⇒ solo icona
    placeholder). Ora costruisce l'`AVURLAsset` sull'URL remoto con gli stessi header di
    autenticazione usati da `PlayerViewModel.makePlayer` per lo streaming, e lo passa ad
    `AVAssetImageGenerator` esattamente come per un file locale: scarica via richieste Range solo
    i pochi byte del fotogramma richiesto, non l'intero video — non più pesante del collegamento
    al Pi già fatto per lo streaming stesso. Nessun'altra modifica serve perché
    `ThumbnailImageView` rigenera già da sola la miniatura mancante al primo utilizzo (vedi sopra,
    stesso meccanismo pensato per la perdita di Caches): un item remoto aggiunto alla libreria
    ottiene la sua miniatura reale la prima volta che la card viene mostrata in griglia.
    ⚠️ **Bug reale trovato e corretto**: un episodio/film aggiunto alla libreria da remoto
    (`RemoteTitleDetailView.addSeasonToLibrary`/`addMovieToLibrary`) ha `duration == 0` finché non
    viene riprodotto almeno una volta (per l'import locale e per il download la durata è già nota
    a questo punto, misurata altrove — qui no). Il calcolo del fotogramma target
    (`duration > 4 ? min(duration * 0.1, 30) : 0`) cadeva quindi sempre a t=0 → quasi sempre nero,
    e ci restava per sempre perché una miniatura già su disco non viene più rigenerata. Fix in
    `generateIfNeeded`: per un item remoto con `duration <= 0`, misura la durata vera
    (`asset.load(.duration)`, stesso `AVURLAsset` con gli header già costruito per il frame) prima
    di scegliere il target, e la scrive anche sul modello (`item.duration =`) così pure la durata
    mostrata prima del primo play si sistema di rimbalzo. Item già aggiunti PRIMA di questo fix e
    con una miniatura nera già in cache non si autoripara da soli (il file esiste già): vanno
    rimossi e riaggiunti alla libreria per rigenerarla.

## Non ancora implementato

- Picture-in-Picture, layout dedicato iPad, sync iCloud.
- Sezione Cerca: poster/metadati (ora solo placeholder a icona), pull-to-refresh del catalogo
  remoto, riconciliazione tra un episodio guardato in streaming e lo stesso poi scaricato
  offline (oggi coesistono come due `MediaItem`), auto-avanzamento a cavallo di stagione
  testato solo con cataloghi piccoli.
