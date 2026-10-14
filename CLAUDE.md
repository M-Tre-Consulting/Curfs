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
Diventerà `it.mtreconsulting.curfs` (iOS e Mac, un'unica scheda App Store) solo al passaggio
all'account Apple Developer della società, non prima: vedi `brand/DISTRIBUZIONE.md` di m-tre-site.

## Vincoli

- **Locandine: due versioni** (dal 2026-10-01). Flag di compilazione `EXTRA_POSTERS`, impostato
  solo nella configurazione **Debug** del progetto: le build personali del proprietario (da Xcode)
  cercano le locandine con Wikipedia + IMDb + iTunes; in **Release** (archivio per App Store / Mac
  App Store) il codice Wikipedia/IMDb è escluso e resta solo iTunes, perché le condizioni d'uso di
  IMDb vietano l'estrazione di dati e le locandine di Wikipedia sono in fair use. Cache separate per
  le due versioni (`PosterFetcher`). L'informativa in `Branding.swift` segue lo stesso flag e
  rimanda a https://mtre-consulting.it/privacy/curfs (testo della versione store: se cambia,
  aggiornare anche la pagina nella repo m-tre-site). Non rimettere IMDb/Wikipedia fuori dal flag.
- **Requisiti store già a posto** (2026-10-01): `Curfs/PrivacyInfo.xcprivacy` (nessun tracciamento né
  dato raccolto; unica API con motivo obbligatorio: `UserDefaults`, CA92.1 — se si aggiungono date di
  file, spazio su disco, uptime ecc. va aggiornato) e `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption =
  NO` in tutti e quattro i blocchi di build dei target (solo HTTPS di sistema, crittografia esente).

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
- `Views/` — schermate libreria (`LibraryHomeView`, `SeriesDetailView`), card (`ShowCardView`,
  `MovieCardView`, `ContinueWatchingCard`, `EpisodeRowView`) e `Views/Search/` (`SearchView`,
  `SearchResultCard`, `RemoteTitleActions`, `RemoteSourceSettingsView`, `DownloadsOverlay`).
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
  fullscreen, menu velocità/audio/sottotitoli già pronti. Il suo Picture-in-Picture è **spento**:
  quello di sistema si aggancia sempre a un angolo e l'utente vuole il video esattamente dove lo
  lascia. Al suo posto `CurfsMac/Player/MacMiniPlayer.swift` (tasto nella barra del player, ⇧⌘P):
  `NSPanel` `.floating` non attivante, su tutte le scrivanie e sopra le app a schermo intero,
  `contentAspectRatio` = proporzioni del video, posizione/grandezza ricordate
  (`setFrameAutosaveName`), trascinabile dalla striscia in alto (`WindowDragGesture`, sul video i clic
  vanno ai controlli). Stesso `PlayerViewModel`: "Torna alla finestra" lo riapre da `RootTabView`
  (`MacPlayerView(resuming:)`), la X fa `vm.stop()`. In modalità compatta `MacVideoPlayerView` non
  installa i tasti A/D (il monitor locale ruberebbe le lettere scritte altrove nell'app) né nasconde
  il cursore.
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
    (`LibraryHomeView`/`SearchView`/`SeriesDetailView`).
  - ⚠️ **`Menu` con `Button` che mutano uno `@State` che ridisegna lo stesso `Menu`**: su macOS
    l'NSMenu può restare bloccato aperto (non capita su iOS, dove UIKit gestisce i menu
    diversamente) — capitato con "Salva in:" (oggi in `SeriesDetailView`). Mitigato rimandando
    l'assegnazione allo `@State` con `Task { @MainActor in ... }` dentro l'azione del `Button`
    invece di farla sincrona. (La vecchia scheda di Cerca era uno sheet con una X di chiusura extra su Mac: dal 2026-10-13
    la scheda serie è una pagina in navigazione, il problema non si pone più.)
- **Barra in alto della finestra Mac** (2.3.3): aveva una fascia nera all'apertura che spariva
  al primo cambio di sezione e non tornava più (sfondo della toolbar mostrato/nascosto da
  SwiftUI a seconda della fase). Fix: `cleanWindowToolbar()` (`Utilities/WindowChrome.swift`,
  `toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`, no-op su iOS) su Libreria/Cerca/
  scheda serie e sulla radice, più `.containerBackground(for: .window) { AppBackground() }` in
  `CurfsMacApp` così durante la dissolvenza tra sezioni non si vede il nero della finestra.
  Confermato dall'utente sull'app vera.
- **Icona**: l'asset catalog `AppIcon.appiconset` (condiviso) aveva già gli slot idiom "mac"
  (16→512, @1x/@2x) ma vuoti. Popolati da `icon-any.png` (quello iOS, quadrato pieno) ricomposto
  in stile Big Sur — margine, angoli arrotondati, ombra morbida — con uno script CoreGraphics
  ad hoc (non con Icon Composer), poi ridimensionato via `sips`.
- **Bundle ID separato**: `com.nicoloperri.CurfsMac` (a differenza di quello iOS, qui non serve
  continuità dati con nessuna installazione precedente).
- **Sandboxata** (dal 2026-09-30, obbligatoria per il Mac App Store — piano di pubblicazione in
  `brand/DISTRIBUZIONE.md` della repo m-tre-site, scheda Curfs): entitlement generati dalle build
  setting `ENABLE_APP_SANDBOX`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS` (Cerca/streaming/locandine),
  `ENABLE_USER_SELECTED_FILES = readonly` (import da `fileImporter`, che copia i video nel
  container: nessun bookmark da conservare). Prima girava senza sandbox e salvava tutto nella home
  (`~/Documents/Library`, `~/Library/Application Support/default.store`/`Thumbnails`/`Downloads`,
  preferenze): `CurfsMac/Support/container-migration.plist` li sposta nel container
  (`~/Library/Containers/com.nicoloperri.CurfsMac/Data/`) al primo avvio sandboxato, una volta
  sola — verificato sul Mac dell'utente. Firma automatica con lo stesso team Apple dell'app iOS
  (development, non Developer ID): un `.dmg` distribuito ad altri fa comparire l'avviso Gatekeeper
  "sviluppatore non identificato" (tasto destro → Apri la prima volta) finché non c'è l'account
  Developer a pagamento.
- **Download remoti**: `RemoteDownloadManager` (condiviso) funziona finché l'app Mac è aperta, ma
  non ha l'aggancio equivalente di `AppDelegate.application(_:handleEventsForBackgroundURLSession:)`
  usato su iOS per il risveglio da app terminata — concetto che su Mac non si applica allo stesso
  modo (l'app non viene sospesa/terminata dal sistema come su iOS).

## Curfs TV (`tv/`, dal 2026-10-14)

Web app per la TV Hisense VIDAA dell'utente, **non Swift**: HTML/CSS/JS senza framework né build
(`tv/app/`, moduli ES), servita dal Pi e aperta da un riquadro nel launcher della TV (installato
con le funzioni di Sidee, vedi `tv/README.md`). Scope voluto dall'utente: libreria, serie →
episodi, film → parte, rimozione, catalogo; **niente sottotitoli e niente download** (una web app
non può salvare video sulla TV). Decisioni:
- `catalog.js` è il port di `FileNameParser` + `HTTPTreeProvider.classify`/`resolveGroupsAndMovies`:
  se cambiano le regole di riconoscimento in Swift, allinearlo.
- Navigazione spaziale in `focus.js` (elemento più vicino nella direzione, classe `f`), niente indici.
- TV lenta (MT9602): niente blur/ombre grandi, solo transform/opacity, scroll senza animazione.
- nginx: ingresso separato `:8092` solo LAN e **senza password** (il `<video>` della TV non gestisce
  la basic auth), `/media/` = cartella video, `/imdb/` = proxy per le locandine IMDb (niente CORS).
- `tv/server/faststart.sh`: sposta il `moov` all'inizio (ffmpeg `-c copy`); senza, sulla TV ~7 s
  per partire. Sul Pi gira anche di notte da cron.

## Decisioni/gotcha non ovvi dal codice

- **Griglie di card responsive**: `LibraryHomeView` / `SearchView` NON usano
  `GridItem(.adaptive(...))` — a larghezze piccole (12 mini / SE, Display Zoom, Dynamic Type
  grande) l'adaptive sceglieva una colonna troppo larga e le card sforavano lo schermo. La
  larghezza va letta da un `GeometryReader` esterno che avvolge l'intera `ScrollView` (non da
  `.onGeometryChange` sulla griglia stessa — quella strada, usata in un primo tentativo, ha un suo
  problema separato, vedi sotto), passata a `CardGrid.columns(forWidth:)`, che restituisce un
  numero intero di colonne `.flexible` (minimo 2): queste NON possono eccedere lo spazio
  disponibile, è garantito dal layout system.
- ✅ **Risolto (2026-09-14) il bug del "margine sinistro perso"** che per mesi era sembrato un
  bug del layout system (`ScrollView`+`VStack`, vedi storia sotto): la causa vera era
  **`AppBackground`**, non le view che sembravano sbagliate. Il cerchio sfocato più grande dello
  sfondo (`Circle().frame(width: 440, height: 440)`) "trapelava" come ideal-size dell'intero
  `ZStack` di sfondo verso l'alto — confermato misurando la geometria a runtime (non solo per
  teoria): su schermi più stretti di 440pt (qualunque iPhone: il più largo, i Pro Max, arriva a
  428/430) lo `ZStack` che contiene `AppBackground()` (in `LibraryHomeView`/`SearchView`/
  `SeriesDetailView`, tutte le view che lo montano) finiva centrato su una
  larghezza fittizia di 440pt invece che sulla larghezza vera dello schermo, spingendo fuori dal
  bordo sinistro tutto il contenuto per metà della differenza — inosservabile sugli schermi più
  larghi (13 Pro Max: solo 6pt di offset, sotto la soglia percepibile), vistoso su quelli più
  stretti (12 mini/11 Pro, 375pt: 32pt di offset, testo tagliato). Spiega perché sembrava
  "isolato in `ContinueWatchingCard`/testi di sezione" (erano solo i figli più a sinistra della
  gerarchia a mostrarlo per primi) e perché nessun tentativo sulla griglia/`VStack`/padding
  aveva funzionato: il problema non era mai stato lì. Fix: `.frame(maxWidth: .infinity)` da solo
  NON basta (con una proposta di size "nil" si limita a inoltrare la richiesta al figlio invece
  di forzare un riempimento) — serve avvolgere il contenuto di `AppBackground` in un
  `GeometryReader`, che riporta sempre e solo la size che gli viene proposta, mai quella dei
  figli, tagliando il leak alla radice. Diagnosticato misurando `g.frame(in: .global)` via sonde
  `GeometryReader` temporanee loggate con `os.Logger` (non `print()`: su simulatore non passa
  per `log stream`/os_log, si perde) e confrontando due simulatori (uno stretto, uno largo)
  creati ad hoc con `xcrun simctl create`/`log stream --predicate 'subsystem == "..."'` — utile
  da ricordare come tecnica se si ripresenta un bug di layout simile "isolato ma non capito".
- Le card di griglia (`ShowCardView`, `MovieCardView`, `SearchResultCard`) usano
  `.aspectRatio(_, contentMode: .fit)` + `.frame(maxWidth: .infinity)` per non spingersi oltre la
  colonna; dove la miniatura ha già un frame fisso (`EpisodeRowView`, header di `SeriesDetailView`)
  resta `.fill` (è comunque limitata).

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
- **Streaming poi scaricato**: restano due `MediaItem`, ma `RemoteDownloadManager.inheritStreamingProgress`
  copia posizione/visto/ultima visione sulla copia scaricata (la voce streaming non si cancella:
  potrebbe essere aperta nel player). A pari data "Continua a guardare" e `findNext` preferiscono il
  file scaricato.
- **Pannello "Prossimo episodio"**: compare all'inizio dei titoli di coda riconosciuti, altrimenti
  negli ultimi 20 s. "Annulla" vale finché non si esce da quella zona (`nextPromptDismissed`); il
  countdown avanza solo mentre il video va (`.task(id: isPresented && isPlaying)`). `isPlaying` segue
  `timeControlStatus` via KVO: le pause decise dal sistema (background, chiamate, cuffie) aggiornano
  l'interfaccia.
- **Picture-in-Picture (iPhone)**: `Player/PictureInPictureSession.swift`, singleton che possiede
  l'**unico** `PlayerLayerContainerView` dell'app (`VideoPlayerLayerView` lo riusa sempre) e il
  controller PiP legato a quel layer. Tasto PiP → parte la finestrella e il player a schermo intero
  si chiude (`dismissToken`), `PlayerView.onDisappear` NON chiama `vm.stop()` se `pip.detach(vm)`;
  "ripristina" riapre il player da `RootTabView` (`restoring` → `PlayerView(resuming:)`, stesso
  `PlayerViewModel`, `start()` idempotente) e il completion di sistema si chiama in `attach`. Uscendo
  dall'app mentre va parte da solo (`canStartPictureInPictureAutomaticallyFromInline`), rientrando
  si richiude (`stopIfPlayerIsOpen`). Chiuso con la X a player chiuso → `vm.stop()` (progressi salvati).
  Serve `UIBackgroundModes = audio`: Xcode non lo accetta come `INFOPLIST_KEY_`, sta in
  `Curfs-iOS-Info.plist` alla radice (fuori dal gruppo sincronizzato, sennò finirebbe anche nel
  target Mac), `INFOPLIST_FILE` solo nei due blocchi del target iOS, unito al plist generato.
- **Barra in alto del player iPhone** (`PlayerControlsOverlay.topBar`): `ViewThatFits` tra la
  versione completa (tutti i tasti: PiP, episodio successivo, rotazione, `TracksMenu`, velocità) col
  titolo `fixedSize` — quindi scelta solo se il titolo ci sta per intero — e quella compatta
  (rotazione + "⋯" `PlayerOptionsMenu` con tutto il resto, sottomenu `Picker` `.menu`). Voluto
  dall'utente: il menu solo quando il titolo verrebbe tagliato. Menu velocità/tracce/"⋯" sono view a
  sé che non leggono `currentTime`: ridisegnandosi 4 volte al secondo il menu aperto perdeva il tocco.
- **Audio/sottotitoli** (`PlayerViewModel.loadMediaSelections`): solo tracce dentro al file
  (`AVMediaSelectionGroup` audible/legible, i sottotitoli "solo forzati" esclusi dalla scelta); le
  voci compaiono solo se c'è qualcosa da scegliere. Su Mac lo dà AVPlayerView. Nel tasto a sé
  (`TracksMenu`) sono liste piatte con intestazione, non sottomenu: nei sottomenu iOS non si può
  trascinare il dito e rilasciare sulla voce (segnalato come "tocco rotto").
  **Nomi delle tracce** (`Player/SubtitleLabeler.swift`): gli mp4 dell'utente (convertiti da mkv)
  hanno 4-5 tracce tx3g tutte `und` → "Lingua sconosciuta" ×5, inutilizzabili. La lingua si
  riconosce dai primi 40 sottotitoli (`AVAssetReader` sulla sola traccia + `NLLanguageRecognizer`,
  soglia 0.8; lituano/lettone non supportati da NL → dalle lettere tipiche, solo se frequenti:
  "Māui" faceva lettone un film inglese), "(non udenti)" da rumori tra parentesi/"Nome:"/tutto
  maiuscolo, "(parti straniere)" se la traccia pesa < 1/7 della più grande, tracce < 200 byte
  nascoste (ce n'è una vuota da 11 byte). Mappa opzione↔traccia per ordine, solo se il numero
  coincide; altrimenti "Sottotitoli N". Verificato su GoT S1 e Oceania.
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
  - **Pre-calcolo prima del play = coda unica `IntroAnalysisQueue`** (MainActor, un worker in
    background, un episodio alla volta, legge la libreria da `AppModelContainer.shared.mainContext`).
    Tutti gli altri punti si limitano ad accodare: avvio app (`IntroCreditsWarmup` →
    `enqueueLibrary`), import da File e download finalizzati (`enqueueShows`: TUTTA la serie,
    i nuovi prima — un episodio nuovo cambia i vicini e quindi la cache degli altri), apertura di
    una stagione in `SeriesDetailView` e episodio successivo nel player (`prioritize`: solo un cambio
    di ordine, passano in testa). ⚠️ **Mai far girare l'analisi dentro un `.task` di una view**:
    bug reale (2026-09-30) — l'analisi girava nel `.task` di `SeriesDetailView`, uscire/cambiare
    stagione lo cancellava a metà di un episodio e `FingerprintExtractor`/`analyze` salvavano
    comunque impronte parziali + risultato vuoto ⇒ quell'episodio restava in cache "analizzato,
    nessuna sigla", uno bruciato a ogni uscita. Ora entrambi **non salvano nulla se
    `Task.isCancelled`**, e i chiamanti in quel caso usano `IntroAnalysisStatus.abandon` invece di
    `finish`. Il player usa un'istanza propria dell'analizzatore, la coda usa `.shared`.
    `isInIntro` ha 5 s di anticipo sul bordo. Lista vicini condivisa via
    `PlayerViewModel.siblingEpisodes(of:in:)`.
  - **Dipende dalla durata reale dell'episodio**: `analyze` esce (senza cache) se `duration < 90`
    — tipico subito dopo l'import, prima che `MediaDurationMeasurer`/`PlayerViewModel.resolveDuration`
    la misurino. `PlayerViewModel.onDurationResolved()` rilancia l'analisi una volta appena la
    durata è nota, così il pulsante compare anche alla PRIMA riproduzione di un episodio appena
    importato invece che solo dalla seconda.
  - **Indicatore di stato** (`IntroAnalysisStatus`, `@Observable`): in `SeriesDetailView` mostra
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
  - **Tasto manuale "Ricalcola"** (icona ⟲ accanto all'indicatore in `SeriesDetailView`): agisce
    **solo sugli episodi della stagione mostrata** (`IntroAnalysisQueue.recompute(ids)`): ferma
    il worker e aspetta che si fermi (così non riscrive i file appena cancellati), cancella i file
    di quegli episodi (`IntroCreditsAnalyzer.resetDiskCache(for:)`, per prefisso UUID),
    `IntroAnalysisStatus.reset(ids)`, poi li rimette in testa alla coda. Le altre stagioni/serie
    non vengono toccate.
- **Scheda serie unica `SeriesDetailView`** (2026-10-13, su richiesta dell'utente: prima c'erano
  due schede diverse — in Cerca uno sheet streaming/aggiungi senza progressi né download per
  episodio, in Libreria una pagina con progressi ma senza download). Ora la stessa pagina (push,
  non sheet) si apre da Cerca e da Libreria e **unisce** gli episodi in libreria (locali + voci
  streaming della serie `showName`) con quelli del catalogo del server, chiave stagione|episodio:
  il locale vince sullo streaming. Da Libreria il titolo remoto si cerca nel catalogo per nome
  (`ShowNameMatcher`, best-effort); da Cerca `showName` è la serie in libreria che corrisponde
  (stesso matcher) o il nome del server, cambiabile con "Salva in:". Tap su un episodio = file
  scaricato se c'è, altrimenti streaming; la "libreria" passata al player contiene tutti gli
  episodi di tutte le stagioni (scaricati e non) per l'auto-avanzamento. Ogni riga ha il proprio
  tasto download con anello di progresso (tocca per annullare) — per questo `RemoteDownloadItem`
  espone ora la `request` (serie/stagione/episodio/titolo) e `RemoteDownloadManager` ha
  `download(show:season:episode:)`/`movieDownload(title:)`. Il catalogo è condiviso tramite
  `RemoteContentProviderRegistry.shared` (si ricrea da solo al cambio di configurazione;
  `invalidate()` per il pull-to-refresh di Cerca) invece di un provider per view.
- **Film**: tap = riproduci subito (in Cerca: il file scaricato se c'è, poi la voce streaming già
  in libreria, sennò una nuova — `RemoteTitleActions.playableMovie`), **tenendo premuto** si
  scarica / si aggiunge ai Film / si cambia copertina. Niente più scheda film a tre pulsanti
  (bocciata dall'utente). In Libreria un film ancora in streaming ha "Scarica per l'offline" nel
  menu contestuale (`RemoteTitleActions.download(_:)`: stesso URL dello streaming).
- **"Continua a guardare"** in home mostra un solo item (l'ultimo in assoluto per
  `lastPlayedAt`), non tutti i video a metà. Dentro una serie, "Riprendi"
  (`ShowSummary.nextToWatch`) punta all'ultimo episodio *di quella serie* effettivamente lasciato
  a metà (per `lastPlayedAt`), non al primo non finito in ordine numerico.
- **Eliminazione libreria**: esistono già eliminazione per singolo episodio/film (context menu),
  intera serie (context menu in home) e singola stagione (tasto cestino in `SeriesDetailView`,
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
    Le righe "Completato" vengono tolte dal registro da sole appena non resta nessun download
    attivo (`BackgroundDownloadEngine.pruneCompletedIfIdle`, anche all'avvio): prima il pannello
    si nascondeva ma quelle non chiuse con la X ricomparivano tutte al download successivo. La X
    su una riga completata toglie solo la riga (l'episodio resta in libreria); su un download in
    corso lo annulla. Le fallite restano finché non si riprovano/chiudono.
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
  - **Aggiungi alla libreria (streaming)** (`SeriesDetailView.addAllToLibrary` /
    `RemoteTitleActions.addMovieToLibrary`): inserisce voci `MediaItem` remote per l'intera stagione / il film
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
    `RemoteTitle.posterURL` (già consumato da `SearchResultCard`/`SeriesDetailView` via
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
    di `SeriesDetailView`) il problema non si presenta comunque.
    `RemotePosterImage` è anche il punto da cui `ShowCardView`/`MovieCardView`/
    `SeriesDetailView.posterArt` mostrano la locandina (2:3, invece del frame video 16:9) per un
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
  - **Copertine scelte dall'utente, salvate sul Pi accanto al contenuto** (2026-09-27): in
    `SeriesDetailView` il pulsante sulla locandina (e per i film il menu contestuale in Cerca,
    `PosterEditor`/`PosterMenuItems` in `RemoteTitleActions.swift`) (iPhone: Foto/File/
    Ripristina; Mac: pulsanti separati, niente `Menu` per il gotcha NSMenu sopra) prende
    un'immagine, la ritaglia al centro a 2:3 e la ridimensiona a max 1000×1500 JPEG
    (`Utilities/PosterImageProcessing`), poi la carica con **PUT** (WebDAV di nginx) tramite
    `RemoteContentProvider.setCustomPoster`. Posizione = convenzione Jellyfin/Kodi, così la
    copertina segue il contenuto (condivisa tra dispositivi, sparisce se si cancella la cartella):
    film → `<nome file video>-poster.jpg` nella stessa cartella; serie → `poster.jpg` nella
    cartella comune a tutti gli episodi se contiene SOLO quella serie, altrimenti
    `<nome serie>-poster.jpg` lì (`HTTPTreeProvider.seriesPosterAnchor`). La scansione raccoglie
    anche i file `poster.*`/`*-poster.*` (jpg/jpeg/png — si possono mettere anche a mano sul Pi)
    e passa l'`mtime` di autoindex come `?v=` nell'URL per non mostrare la versione in cache.
    Vincono su iTunes via `PosterFetcher.overrides`, **sostituiti per intero a ogni costruzione
    del catalogo** (così un titolo tolto dal server perde la copertina) e salvati in
    `Caches/RemotePosterOverrides.json` solo perché le card della libreria (`RemotePosterImage`,
    per nome come prima) la mostrino anche prima che Cerca abbia caricato il catalogo.
    Lato server serve `dav_methods PUT DELETE` in nginx **solo** per i nomi file poster
    (location regex), senza → 405 → `RemoteProviderError.uploadNotSupported`. Le immagini
    remote passano per `Utilities/RemoteImage` (non `AsyncImage`): aggiunge gli header di
    basic-auth del Pi, che `AsyncImage` non permette. Limite: la card della libreria trova la
    copertina per nome, quindi una serie salvata con "Salva in:" sotto un nome diverso da quello
    del Pi non la vede.
  - **Catena locandine automatiche** (`PosterFetcher.automaticPosterURL`), tutte senza chiavi/account:
    1. **Wikipedia riconosce il titolo** (`wikiIdentify`): cerca "<titolo> film"/"serie
       televisiva" su it.wiki (titoli italiani: "Oceania" → "Oceania (film 2026)"), segue il
       `langlinks` alla voce INGLESE, poi prova direttamente en.wiki. Match sul titolo della voce
       senza disambigua; con un anno nel nome vale solo la voce che lo riporta o quella senza
       disambigua, mai un'altra versione datata. Una voce vale come riconoscimento solo se la
       disambigua dice film/serie ("(film 2026)", "(TV series)") o se ha un'immagine a forma di
       locandina: evita "Oceania" il continente.
    2. **IMDb dà la locandina in alta risoluzione** (`fetchIMDb`) cercando il titolo INGLESE
       riconosciuto al punto 1 (+ anno da nome file o disambigua): endpoint dei suggerimenti
       della barra di ricerca del sito, `v3.sg.media-imdb.com/suggestion/<iniziale>/<query>.json`.
       ⚠️ **Non è un'API ufficiale** (quella vera è a pagamento via AWS): può cambiare/sparire,
       l'utente lo sa e l'ha accettato; se fallisce si ricade sui passi successivi. Match: titolo
       normalizzato identico + tipo (`qid` movie/tvMovie o tvSeries/tvMiniSeries) + anno (±1) se
       noto, immagine verticale (≥ 1,2: alcune locandine IMDb sono 4:5). `._V1_.jpg` →
       `._V1_UX1000_.jpg` per averla già a 1000 px di larghezza.
    3. La locandina di Wikipedia della voce riconosciuta: **piccola per regola** (fair use delle
       immagini non libere, ~250×380 all'origine, es. Moana 2026 258×384 — su una card Retina si
       vedeva sgranata: era il motivo per aggiungere IMDb). Serve `pilicense=any`; accettata solo
       se verticale (≥ 1,3). 
    4. iTunes (vedi sotto), artwork chiesto a `1000x1500bb` (per le serie è quadrato, 1000×1000).
    TMDB è stato provato e **tolto su richiesta dell'utente** (richiede registrazione; il modulo
    rifiutava l'indirizzo italiano): non reintrodurlo. User-Agent identificativo obbligatorio per
    Wikimedia (`PosterFetcher.wikimediaUserAgent`, mandato anche da `RemoteImageLoader` per
    `*.wikimedia.org`). Cache con prefisso `v6|`. Verificato il 2026-09-27 sui titoli del Pi:
    tutti da IMDb a ~1000 px, compresi Il Trono di Spade (→ Game of Thrones) e Deep State che con
    Wikipedia/iTunes non avevano nulla. ⚠️ Le riserve (Wikipedia, iTunes) finiscono in cache solo
    se nessuna fonte migliore è **fallita per rete**: bug reale (2026-09-30, prima apertura dell'app
    Mac sandboxata con cache vuota) — IMDb in errore passeggero e Game of Thrones fissato per sempre
    sul pageimage di Wikipedia, che in quel momento era la copertina del videogioco Telltale.
  - **Anno nei titoli dei film remoti**: `FileNameParser.cleanTitle` toglie tutto ciò che sta tra
    parentesi, anche l'anno — `HTTPTreeProvider.movieTitle` lo riaggiunge ("Oceania (2026).mp4" /
    "Oceania.2026.1080p.mp4" → "Oceania (2026)"), perché serve alle fonti delle locandine per
    distinguere un remake dall'originale. Non all'inizio del nome ("1917") e non se è parte del
    titolo ("Blade Runner 2049").
  - ⚠️ **iTunes: un risultato vale solo se il titolo combacia** (`PosterFetcher.candidateNames`,
    confronto normalizzato senza anno tra parentesi; per le serie su `artistName` o
    `collectionName` senza ", Season N"). Conseguenza voluta: i titoli tradotti non si trovano più
    ("Il Trono di Spade" → iTunes USA risponde "Game of Thrones", che prima veniva preso per
    fortuna come primo risultato tv). Provato ad accettarli quando i risultati contengono una sola
    serie: scartato, iTunes restituisce numero/ordine di risultati instabili (con `limit=10`
    Game of Thrones non c'è, con 25 ci sono due serie) e accetterebbe spazzatura ("Moana" →
    *Chibi Tiny Tales*). Per quelli c'è la copertina manuale. Prima si prendeva il primo `feature-movie` qualunque:
    la ricerca iTunes restituisce quasi sempre qualche film ("Oceania" → *The Burned Barns*,
    "Moana" → *A Minecraft Movie*). Chiavi di cache con prefisso versionato (oggi `v6|`) per scartare i
    risultati delle versioni precedenti. Nota: a settembre 2026 la ricerca non trova come film nemmeno titoli
    come *Inception*/*The Matrix* (con o senza `media=movie`), per questo i film li trovano
    Wikipedia + IMDb (sopra); iTunes resta l'ultima riserva, utile soprattutto per le serie.
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
    (`SeriesDetailView.addAllToLibrary`/`RemoteTitleActions.addMovieToLibrary`) ha `duration == 0` finché non
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

- **Firma M-Tre / privacy / licenza** (2.3.0, guida `brand/README.md` della repo
  `M-Tre-Consulting/m-tre-site`): `Utilities/Branding.swift` (`MTre`, `BrandFooter`,
  `LegalView`, `LegalSheet`), image set `MTreLogo`. Firma in fondo a `RemoteSourceSettingsView`
  (ultima sezione del `Form`, sotto la riga "Privacy, licenza e contatti") — prima stava in un
  `safeAreaInset(.bottom)` della Libreria senza sfondo e su iPhone il contenuto ci scorreva sotto
  sovrapponendosi; spostata su richiesta dell'utente. ⓘ in toolbar della Libreria su iPhone, voce
  "Privacy, licenza e contatti…" nel menu app su Mac (finestra `Window(id: "legal")`).
  `NSHumanReadableCopyright` su tutti i target. La repo è pubblica con licenza **MIT**: la
  schermata dice MIT, non la licenza proprietaria della guida. L'informativa descrive cosa fa
  davvero l'app (server dell'utente, titoli inviati a Wikipedia/IMDb/iTunes per le locandine):
  se si aggiunge una nuova connessione o un permesso, aggiornarla con la data.
- **Lingue** (2.3.0, come MarkIt): italiano, inglese, spagnolo, francese, tedesco, scelte dalla
  lingua di sistema; tutte le altre ricadono sull'**inglese** (`developmentRegion = en`,
  `sourceLanguage` del catalogo = en). Le **chiavi sono in italiano** nel codice e le traduzioni
  (anche l'italiano) stanno in `Curfs/Localizable.xcstrings`; `Curfs/InfoPlist.xcstrings` traduce
  `NSHumanReadableCopyright`. Entrambi nel gruppo sincronizzato ⇒ in tutti e due i target.
  ⚠️ I testi costruiti come `String` (ternari, funzioni che restituiscono `String`, messaggi
  d'errore, stati) NON vengono tradotti da `Text`/`Label`: vanno scritti con
  `String(localized:)`. I plurali (`%lld episodi`, `%lld stagioni`, …) usano le variazioni
  plural del catalogo. Un testo nuovo va aggiunto al catalogo in tutte e 5 le lingue (Xcode
  aggiunge la chiave da solo quando si builda dall'IDE, ma senza traduzioni). I testi dell'app
  sono generici (nessun riferimento al Pi/tailnet del proprietario): tenerli così.
- **Catalogo vuoto con il Pi a singhiozzo** (2026-10-13): `HTTPTreeProvider.walk` salta le
  sottocartelle che non si lasciano elencare, ma un errore di rete (`.unreachable`) su una di
  queste ora fa fallire tutto il caricamento. Prima veniva saltato anche quello: con la radice
  raggiungibile e le sottocartelle in errore il catalogo risultava vuoto ("0 elementi" anche nel
  test di connessione) e `replaceOverrides([])` cancellava le copertine personalizzate in memoria.
- **Download e fluidità**: `BackgroundDownloadEngine` avvisa la UI dell'avanzamento al massimo
  ogni 0,25 s (il callback `didWriteData` arriva centinaia di volte al secondo e faceva scattare
  lo scorrimento della scheda serie). Per lo stesso motivo in `SeriesDetailView` i download li
  osservano solo `DownloadControl`/`SeasonDownloadButton`, non il `body` della pagina.
- **"Errore TLS" su Mac = Tailscale spento**, non la firma dell'app: senza tailnet il nome
  `*.ts.net` si risolve col DNS pubblico ai frontend di Tailscale (185.40.234.x) che chiudono
  l'handshake (`SSL_ERROR_SYSCALL`, `URLError.secureConnectionFailed`). `HTTPTreeProvider.send`
  traduce gli errori di rete in `RemoteProviderError.unreachable`, con un messaggio che dice di
  accendere Tailscale.

## Non ancora implementato

- Layout dedicato iPad, sync iCloud. Sottotitoli esterni (.srt accanto al file): oggi solo le tracce dentro al file.
- Sezione Cerca: altri metadati oltre alla locandina (anno, descrizione — ora solo quello che si
  ricava dai nomi file), auto-avanzamento a cavallo di stagione testato solo con cataloghi piccoli.
