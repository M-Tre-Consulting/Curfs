//
//  PlayerViewModel.swift
//  Curfs
//
//  Incapsula l'AVPlayer e tutto lo stato del player: play/pausa, avanzamento,
//  salvataggio periodico della posizione su SwiftData, riconoscimento
//  dell'episodio successivo nella stessa serie.
//

import Foundation
@preconcurrency import AVFoundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class PlayerViewModel {
    let item: MediaItem
    let player: AVPlayer
    var nextEpisode: MediaItem?

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isScrubbing = false
    var controlsVisible = true
    var showNextEpisodePrompt = false
    var didFinish = false
    var playbackRate: Double = 1.0
    var isLandscape = false
    var isInIntro = false
    var isInCredits = false

    /// Finché la durata reale non è nota, lo slider non è affidabile: uno
    /// scrub in quella finestra finirebbe per cercare una posizione quasi a
    /// zero (perché il range dello slider sarebbe anch'esso quasi a zero).
    var isDurationReady: Bool { duration >= 1 }

    private var modelContext: ModelContext?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var hideControlsTask: Task<Void, Never>?
    private var introCreditsTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var lastSavedAt: Date = .distantPast

    /// Altri episodi della stessa serie, ordinati per vicinanza a questo:
    /// usati da IntroCreditsAnalyzer per riconoscere sigla/coda per davvero,
    /// confrontando i fotogrammi invece di indovinare dal timing.
    private let siblingEpisodes: [MediaItem]
    private let introCreditsAnalyzer = IntroCreditsAnalyzer()
    private var detectedIntroRange: ClosedRange<Double>?
    private var detectedCreditsRange: ClosedRange<Double>?

    private static let playbackRateDefaultsKey = "Curfs.playbackRate"

    private static let controlsAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Più rapida e senza rimbalzo: usata solo quando i controlli
    /// appaiono/spariscono insieme alla rotazione fisica dello schermo
    /// (gestita da UIKit, non tunabile), per restare "in sincrono" con
    /// quella invece di seguirla in ritardo con la molla più lenta di sopra.
    private static let orientationControlsAnimation = Animation.easeOut(duration: 0.22)

    init(item: MediaItem, library: [MediaItem]) {
        self.item = item
        self.player = Self.makePlayer(for: item)
        self.duration = item.duration
        self.nextEpisode = Self.findNext(after: item, in: library)

        // Il riconoscimento sigla/coda confronta fotogrammi reali tra episodi:
        // per lo streaming vorrebbe dire scaricare frame di ogni episodio via
        // rete. Lo facciamo solo per la libreria locale.
        self.siblingEpisodes = Self.siblingEpisodes(of: item, in: library)

        let savedRate = UserDefaults.standard.double(forKey: Self.playbackRateDefaultsKey)
        self.playbackRate = savedRate > 0 ? savedRate : 1.0
    }

    /// Altri episodi locali della stessa serie, ordinati per vicinanza a
    /// `item` (l'episodio prima/dopo per primi). Vuoto per film o item in
    /// streaming. Condiviso tra il player e il pre-calcolo del "salta intro".
    static func siblingEpisodes(of item: MediaItem, in library: [MediaItem]) -> [MediaItem] {
        guard item.kind == .episode, !item.isRemote, let show = item.showName else { return [] }
        return library
            .filter { $0.kind == .episode && !$0.isRemote && $0.showName == show && $0.id != item.id }
            .sorted { distance($0, from: item) < distance($1, from: item) }
    }

    /// Costruisce l'AVPlayer: per un item locale dal file, per un item in
    /// streaming da un `AVURLAsset` remoto con gli header di autenticazione
    /// del server (necessari a ogni richiesta Range che il player fa da solo).
    private static func makePlayer(for item: MediaItem) -> AVPlayer {
        let player: AVPlayer
        if item.isRemote {
            let headers = RemoteSourceStore.current.authHeaders
            let options: [String: Any] = headers.isEmpty
                ? [:]
                : ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: item.playbackURL, options: options)
            let playerItem = AVPlayerItem(asset: asset)
            // Streaming dal Pi: bufferizza avanti con abbondanza (i file sono
            // ~5-15 Mbit/s e la banda non è un problema) così un intoppo
            // momentaneo del server o della rete non diventa uno stallo
            // visibile. Il player scarica comunque solo ciò che gli serve.
            playerItem.preferredForwardBufferDuration = 60
            player = AVPlayer(playerItem: playerItem)
        } else {
            player = AVPlayer(url: item.playbackURL)
        }
        // Meglio attendere di avere buffer a sufficienza che partire e
        // singhiozzare (è già il default, lo fissiamo per non perderlo).
        player.automaticallyWaitsToMinimizeStalling = true
        // Niente AirPlay "video": i file locali stanno nella sandbox (non
        // raggiungibili dal ricevitore) e gli header di auth dello streaming non
        // verrebbero propagati alla TV — in entrambi i casi il ricevitore resta
        // in caricamento infinito. Per vedere i contenuti in TV si usa la
        // duplicazione schermo da Centro di Controllo: con l'external playback
        // disattivato il player resta un normale video mirrorato invece di
        // provare a delegare la riproduzione al dispositivo esterno.
        player.allowsExternalPlayback = false
        return player
    }

    /// "Distanza" in episodi tra due elementi della stessa serie, per
    /// preferire il confronto con gli episodi più vicini (di solito
    /// condividono la stessa sigla anche quando cambia tra una stagione e
    /// l'altra).
    private static func distance(_ a: MediaItem, from b: MediaItem) -> Int {
        let seasonDelta = abs((a.seasonNumber ?? 0) - (b.seasonNumber ?? 0)) * 1000
        let episodeDelta = abs((a.episodeNumber ?? 0) - (b.episodeNumber ?? 0))
        return seasonDelta + episodeDelta
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start() {
        activateAudioSession()

        // Prima di tutto il resto: se non è già in cache, l'analisi della
        // sigla è la cosa più lenta e deve partire il prima possibile per
        // avere una speranza di essere pronta prima che la sigla finisca.
        if !siblingEpisodes.isEmpty {
            analyzeIntroCredits()
            prewarmNextEpisode()
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.handleTick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleReachedEnd() }
        }

        if !isDurationReady {
            resolveDuration()
        }

        let resumeAt = item.playbackPosition
        if resumeAt > 3, duration <= 0 || resumeAt < duration - 5 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            currentTime = resumeAt
        }
        play()
        scheduleAutoHide()
    }

    /// `resetOrientation`: `false` quando si passa all'episodio successivo
    /// (vedi PlayerView.playNext) per non forzare il verticale a metà
    /// transizione — la rotazione corrente deve restare quella che era.
    func stop(resetOrientation: Bool = true) {
        if let token = timeObserverToken { player.removeTimeObserver(token) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        hideControlsTask?.cancel()
        introCreditsTask?.cancel()
        prewarmTask?.cancel()
        player.pause()
        persistProgress(force: true)
        deactivateAudioSession()
        if resetOrientation { self.resetOrientation() }
    }

    /// Confronta i fotogrammi di questo episodio con quelli di un paio di
    /// altri della stessa serie per riconoscere per davvero il tratto in
    /// comune (sigla o titoli di coda). Gira in background: se l'episodio
    /// non è ancora stato analizzato per gli altri, la prima volta richiede
    /// qualche secondo, poi il risultato resta in cache su disco.
    private func analyzeIntroCredits() {
        introCreditsTask?.cancel()
        let episode = item
        introCreditsTask = Task { [weak self] in
            guard let self else { return }
            IntroAnalysisStatus.shared.begin(episode.id)
            let result = await self.introCreditsAnalyzer.analyze(item: self.item, siblings: self.siblingEpisodes)
            guard !Task.isCancelled else { return }
            self.detectedIntroRange = result.introRange
            self.detectedCreditsRange = result.creditsRange
            IntroAnalysisStatus.shared.finish(episode.id, foundIntro: result.introRange != nil)
        }
    }

    /// Mentre si guarda questo episodio, precalcola in background l'impronta
    /// del prossimo: così quando si passa oltre (binge watching) il "salta
    /// intro" è già pronto invece di dover decodificare i fotogrammi al volo.
    private func prewarmNextEpisode() {
        guard let next = nextEpisode, !next.isRemote else { return }
        let nextSiblings = Self.siblingEpisodes(of: next, in: [item] + siblingEpisodes)
        guard !nextSiblings.isEmpty else { return }
        prewarmTask?.cancel()
        prewarmTask = Task(priority: .utility) {
            switch IntroCreditsAnalyzer.cacheStatus(for: next, siblings: nextSiblings) {
            case .readyWithIntro:
                IntroAnalysisStatus.shared.markCached(next.id, foundIntro: true)
                return
            case .readyNoIntro:
                IntroAnalysisStatus.shared.markCached(next.id, foundIntro: false)
                return
            case .missing:
                break
            }
            IntroAnalysisStatus.shared.begin(next.id)
            let result = await IntroCreditsAnalyzer.shared.warm(item: next, siblings: nextSiblings)
            IntroAnalysisStatus.shared.finish(next.id, foundIntro: result.introRange != nil)
        }
    }

    /// L'audio deve sentirsi sempre, anche con la levetta dello squillo su
    /// silenzioso: la categoria .playback è pensata esattamente per questo
    /// (è quella che usano tutte le app di video/musica).
    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
        // Su macOS non esiste AVAudioSession: il sistema gestisce la sessione
        // audio da solo, non serve nessuna richiesta esplicita.
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Riprova più volte a leggere la durata reale del video: su alcuni file,
    /// subito dopo l'import, la prima lettura può fallire o tornare 0 in modo
    /// transitorio. Finché non troviamo un valore attendibile, lo slider
    /// resta disabilitato (vedi isDurationReady) per non permettere scrub
    /// finiti quasi a zero.
    private func resolveDuration() {
        Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<6 {
                if Task.isCancelled { return }
                if let asset = self.player.currentItem?.asset,
                   let seconds = try? await asset.load(.duration).seconds,
                   seconds.isFinite, seconds >= 1 {
                    self.duration = seconds
                    self.item.duration = seconds
                    self.onDurationResolved()
                    return
                }
                if let seconds = self.player.currentItem?.duration.seconds,
                   seconds.isFinite, seconds >= 1 {
                    self.duration = seconds
                    self.item.duration = seconds
                    self.onDurationResolved()
                    return
                }
                if attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }

    /// L'analisi "salta intro" ha bisogno della durata reale dell'episodio
    /// (e dei vicini). Se al momento del play la durata non era ancora nota
    /// — tipico appena dopo l'import — il primo tentativo torna a vuoto e il
    /// pulsante non compare "alla prima": appena la durata è disponibile
    /// rilanciamo l'analisi una volta.
    private var didRetryIntroAnalysis = false
    private func onDurationResolved() {
        guard !didRetryIntroAnalysis,
              !siblingEpisodes.isEmpty,
              detectedIntroRange == nil,
              detectedCreditsRange == nil,
              isDurationReady else { return }
        didRetryIntroAnalysis = true
        analyzeIntroCredits()
        prewarmNextEpisode()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        player.rate = Float(playbackRate)
        isPlaying = true
        scheduleAutoHide()
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying { player.rate = Float(rate) }
        UserDefaults.standard.set(rate, forKey: Self.playbackRateDefaultsKey)
    }

    func pause() {
        player.pause()
        isPlaying = false
        hideControlsTask?.cancel()
        withAnimation(Self.controlsAnimation) { controlsVisible = true }
    }

    func skip(by delta: Double) {
        let upperBound = duration > 0 ? duration : currentTime + max(delta, 0)
        let target = max(0, min(currentTime + delta, upperBound))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginScrubbing() {
        isScrubbing = true
        hideControlsTask?.cancel()
    }

    func endScrubbing(to seconds: Double) {
        // Se la durata non è ancora affidabile, ignoriamo lo scrub invece di
        // cercare una posizione quasi-zero (vedi isDurationReady).
        if isDurationReady {
            seek(to: seconds)
        }
        isScrubbing = false
        scheduleAutoHide()
    }

    func toggleControls() {
        withAnimation(Self.controlsAnimation) {
            controlsVisible.toggle()
        }
        if controlsVisible { scheduleAutoHide() }
    }

    func dismissNextEpisodePrompt() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showNextEpisodePrompt = false
        }
    }

    /// Salta la sigla iniziale, se ne è stata riconosciuta una per davvero
    /// (confronto con altri episodi, vedi IntroCreditsAnalyzer).
    /// Piccolo cuscinetto oltre il bordo rilevato: la coda della sigla
    /// (dissolvenza in entrata, cartello col titolo dell'episodio) non combacia
    /// tra episodi e non viene rilevata, quindi il bordo "vero" è qualche
    /// frazione di secondo più avanti. Meglio entrare di un attimo nella scena
    /// che lasciare un residuo di sigla.
    private let skipIntroPad: Double = 1.2

    func skipIntro() {
        guard let range = detectedIntroRange else { return }
        let cap = duration > 0 ? duration - 1 : range.upperBound + skipIntroPad
        seek(to: min(range.upperBound + skipIntroPad, cap))
    }

    /// Ruota manualmente il player: utile con il blocco di rotazione attivo,
    /// perché una richiesta esplicita dell'app lo scavalca comunque.
    /// Comportamento dopo la rotazione:
    /// - se si torna in verticale, i controlli riappaiono sempre;
    /// - se si passa in orizzontale, riappaiono solo se il video è in pausa,
    ///   altrimenti restano nascosti (nessun timer, nessun "riappaiono da
    ///   soli"): da lì in poi torna il normale tap per mostrarli/nasconderli.
    func toggleOrientation() {
        #if os(iOS)
        isLandscape.toggle()
        hideControlsTask?.cancel()
        let shouldShowControls = !isLandscape || !isPlaying
        withAnimation(Self.orientationControlsAnimation) { controlsVisible = shouldShowControls }
        if controlsVisible { scheduleAutoHide() }
        OrientationController.requestOrientation(isLandscape ? .landscape : .portrait)
        #endif
        // Su Mac non esiste un concetto di rotazione: la finestra è sempre
        // "orizzontale" e ridimensionabile, i controlli sono quelli nativi
        // di AVKit (vedi MacPlayerView), non c'è nulla da forzare qui.
    }

    func resetOrientation() {
        #if os(iOS)
        guard isLandscape else { return }
        isLandscape = false
        OrientationController.requestOrientation(.portrait)
        #endif
    }

    private func handleTick(_ time: CMTime) {
        guard !isScrubbing else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds
        item.playbackPosition = seconds

        // Piccolo anticipo sul bordo iniziale: se l'analisi finisce mentre la
        // sigla è già partita, il pulsante compare comunque subito invece di
        // "mancare il treno".
        if let intro = detectedIntroRange {
            isInIntro = seconds >= intro.lowerBound - 5 && seconds <= intro.upperBound
        } else {
            isInIntro = false
        }

        let inCredits = detectedCreditsRange?.contains(seconds) ?? false
        if inCredits, !isInCredits {
            // Appena entrati nei titoli di coda: da qui in poi non avrebbe
            // senso "continuare a guardare", quindi l'episodio conta già
            // come visto ai fini della libreria (senza toccare didFinish,
            // riservato al vero e proprio raggiungimento della fine).
            item.isFinished = true
        } else if !inCredits, item.isFinished, !didFinish {
            // L'utente è tornato indietro rispetto ai titoli di coda (es.
            // con lo scrubber): l'episodio torna "in corso" a tutti gli effetti.
            item.isFinished = false
        }
        isInCredits = inCredits

        if duration > 20, duration - seconds < 20, !showNextEpisodePrompt, nextEpisode != nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showNextEpisodePrompt = true
            }
        }
        persistProgress(force: false)
    }

    private func handleReachedEnd() {
        isPlaying = false
        item.isFinished = true
        item.playbackPosition = 0
        persistProgress(force: true)
        didFinish = true
    }

    private func persistProgress(force: Bool) {
        item.lastPlayedAt = .now
        guard force || Date.now.timeIntervalSince(lastSavedAt) > 5 else { return }
        lastSavedAt = .now
        // Un item in streaming aperto dalla sezione Cerca non è ancora in un
        // contesto SwiftData: lo inseriamo solo quando c'è qualcosa da
        // ricordare davvero (un minimo di avanzamento, o l'averlo finito),
        // così "Continua a guardare" funziona senza intasare la libreria di
        // titoli solo sfiorati.
        if item.modelContext == nil {
            guard item.playbackPosition > 5 || item.isFinished else { return }
            modelContext?.insert(item)
        }
        try? modelContext?.save()
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.isPlaying, !self.isScrubbing else { return }
            withAnimation(Self.controlsAnimation) { self.controlsVisible = false }
        }
    }

    static func findNext(after item: MediaItem, in library: [MediaItem]) -> MediaItem? {
        guard item.kind == .episode,
              let show = item.showName,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }

        let sameShow = library.filter { $0.kind == .episode && $0.showName == show }
        if let next = sameShow.first(where: { $0.seasonNumber == season && $0.episodeNumber == episode + 1 }) {
            return next
        }
        let laterSeasons = sameShow.filter { ($0.seasonNumber ?? 0) > season }
        return laterSeasons.sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }.first
    }
}
