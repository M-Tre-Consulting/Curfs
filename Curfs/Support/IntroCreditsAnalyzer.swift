//
//  IntroCreditsAnalyzer.swift
//  Curfs
//
//  Riconoscimento REALE di sigla iniziale e titoli di coda: confronta
//  l'impronta dell'episodio corrente (vedi FingerprintExtractor) con quella
//  di un paio di altri episodi della stessa serie, cerca lo sfalsamento
//  temporale che fa combaciare più fotogrammi possibile, e individua il
//  tratto continuo di fotogrammi "uguali" tra i due episodi: quello è il
//  segmento realmente in comune (sigla o coda), non un'ipotesi sul timing.
//  Se non c'è nessun episodio con cui confrontare (es. un solo episodio
//  importato), semplicemente non viene riconosciuto nulla: niente pulsante
//  "salta intro" indovinato a caso.
//
//  Il risultato dell'analisi è messo in cache su disco per episodio
//  (IntroCreditsStorage): dalla seconda volta è immediato e — soprattutto —
//  identico, invece di riconfrontarsi ogni volta coi vicini del momento.
//

import Foundation

actor IntroCreditsAnalyzer {
    /// Istanza condivisa per il pre-calcolo (import, apertura scheda serie):
    /// il player usa la propria, così un pre-calcolo lungo non fa la coda
    /// davanti all'analisi dell'episodio che stai per guardare.
    static let shared = IntroCreditsAnalyzer()

    private let extractor = FingerprintExtractor()

    /// Bump quando cambia la logica di match qui sotto o il campionamento in
    /// FingerprintExtractor: invalida i risultati già in cache.
    static let analysisVersion = 10

    /// "Firma" dei vicini usati per il confronto (id + durata): se cambia il
    /// set di vicini, la cache del risultato non è più valida.
    nonisolated static func siblingSignature(_ siblings: [MediaItem]) -> String {
        siblings.prefix(3)
            .map { "\($0.id.uuidString):\(Int($0.duration.rounded()))" }
            .joined(separator: "|")
    }

    enum CacheStatus {
        case missing          // da (ri)calcolare
        case readyNoIntro     // analizzato: nessuna sigla in comune trovata
        case readyWithIntro   // analizzato: sigla trovata, il pulsante comparirà
    }

    /// Stato della cache su disco per questo episodio (versione + durata +
    /// vicini invariati). Solo lettura, per l'indicatore di stato — non
    /// calcola nulla. Distingue "analizzato ma nessuna sigla trovata" da
    /// "sigla pronta": un risultato può essere validamente in cache senza che
    /// sia stata trovata una sigla (vedi IntroAnalysisStatus).
    nonisolated static func cacheStatus(for item: MediaItem, siblings: [MediaItem]) -> CacheStatus {
        guard item.duration >= 90, let cached = IntroCreditsStorage.load(for: item.id),
              cached.version == analysisVersion,
              cached.itemDuration == item.duration,
              cached.siblingSignature == siblingSignature(siblings)
        else { return .missing }
        return (cached.introLower != nil && cached.introUpper != nil) ? .readyWithIntro : .readyNoIntro
    }

    /// Cancella la cache su disco di sigla/coda (impronte + risultati) SOLO
    /// per questi episodi — usata dal tasto manuale "Ricalcola" in
    /// `SeriesDetailView` per la stagione mostrata, quando l'utente non si fida
    /// del risultato. I file di un episodio iniziano tutti con il suo UUID
    /// (`<id>-v<N>.json`, `<id>-introcredits.json`).
    nonisolated static func resetDiskCache(for ids: [UUID]) {
        let dir = LibraryStorage.fingerprintsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefixes = ids.map { $0.uuidString + "-" }
        for url in contents where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Durata minima del tratto in comune perché conti come sigla/coda:
    /// esclude musiche di sottofondo brevi che tornano, sotto la durata di
    /// qualunque sigla/coda vera.
    private let minMatchSeconds: Double = 10

    struct Result {
        var introRange: ClosedRange<Double>?
        var creditsRange: ClosedRange<Double>?
    }

    /// `siblings` dovrebbe già contenere solo episodi della stessa serie
    /// (escluso `item`), idealmente ordinati per vicinanza (es. episodio
    /// precedente/successivo prima): ne vengono confrontati al più i primi 3.
    func analyze(item: MediaItem, siblings: [MediaItem]) async -> Result {
        // Senza una durata attendibile (tipico appena dopo l'import) l'analisi
        // non può funzionare: non calcoliamo né mettiamo in cache un risultato
        // vuoto che poi resterebbe lì — verrà ritentata quando la durata è nota.
        guard item.duration >= 90 else { return Result(introRange: nil, creditsRange: nil) }

        let usableSiblings = Array(siblings.prefix(3))
        let signature = Self.siblingSignature(usableSiblings)

        if let cached = IntroCreditsStorage.load(for: item.id),
           cached.version == Self.analysisVersion,
           cached.itemDuration == item.duration,
           cached.siblingSignature == signature {
            return Result(
                introRange: range(cached.introLower, cached.introUpper),
                creditsRange: range(cached.creditsLower, cached.creditsUpper)
            )
        }

        let result = await computeAnalysis(item: item, siblings: usableSiblings)

        // Analisi interrotta (es. "Ricalcola", player chiuso): il risultato è
        // incompleto e NON va messo in cache, altrimenti l'episodio resterebbe
        // "analizzato, nessuna sigla" per sempre. Il chiamante controlla
        // `Task.isCancelled` e non lo considera pronto.
        guard !Task.isCancelled else { return result }

        IntroCreditsStorage.save(
            IntroCreditsCache(
                version: Self.analysisVersion,
                itemDuration: item.duration,
                siblingSignature: signature,
                introLower: result.introRange?.lowerBound,
                introUpper: result.introRange?.upperBound,
                creditsLower: result.creditsRange?.lowerBound,
                creditsUpper: result.creditsRange?.upperBound
            ),
            for: item.id
        )
        return result
    }

    private func range(_ lower: Double?, _ upper: Double?) -> ClosedRange<Double>? {
        guard let lower, let upper, lower <= upper else { return nil }
        return lower...upper
    }

    /// Scalda la cache dell'impronta di un episodio senza fare il confronto:
    /// usato per preparare l'episodio successivo mentre si guarda quello
    /// corrente, così il "salta intro" è pronto appena ci si arriva.
    func prewarm(_ item: MediaItem) async {
        await extractor.prewarm(item)
    }

    /// Esegue (e mette in cache) l'analisi completa per un episodio: serve a
    /// farla trovare già pronta al primo play — chiamata dall'import e
    /// all'apertura della scheda di una serie. Il risultato viene restituito
    /// (non solo scartato) così il chiamante sa se è stata trovata una sigla
    /// o no, per l'indicatore di stato.
    @discardableResult
    func warm(item: MediaItem, siblings: [MediaItem]) async -> Result {
        await analyze(item: item, siblings: siblings)
    }

    private func computeAnalysis(item: MediaItem, siblings: [MediaItem]) async -> Result {
        guard let mine = await extractor.fingerprint(for: item) else {
            return Result(introRange: nil, creditsRange: nil)
        }

        var introCandidates: [ClosedRange<Double>] = []
        var creditsCandidates: [ClosedRange<Double>] = []

        for sibling in siblings {
            if Task.isCancelled { break }
            guard let theirs = await extractor.fingerprint(for: sibling) else { continue }

            if let match = Self.bestMatch(mine.tracks.map(\.introCodes), mine.tracks.map(\.language),
                                          theirs.tracks.map(\.introCodes), theirs.tracks.map(\.language),
                                          minSeconds: minMatchSeconds),
               let range = await VideoMatchVerifier.verify(
                   mine: item.fileURL, theirs: sibling.fileURL,
                   pieces: match.pieces.map { piece in (
                       range: Double(piece.range.lowerBound) / AudioFingerprint.rate...Double(piece.range.upperBound) / AudioFingerprint.rate,
                       offset: Double(piece.offset) / AudioFingerprint.rate
                   ) }
               ) {
                introCandidates.append(range)
            }
            if let match = Self.bestMatch(mine.tracks.map(\.creditsCodes), mine.tracks.map(\.language),
                                          theirs.tracks.map(\.creditsCodes), theirs.tracks.map(\.language),
                                          minSeconds: minMatchSeconds) {
                // I titoli di coda cambiano da un episodio all'altro (i nomi
                // scorrono diversi): lì conta solo l'audio.
                let start = mine.creditsStart + Double(match.range.lowerBound) / AudioFingerprint.rate
                let end = mine.creditsStart + Double(match.range.upperBound) / AudioFingerprint.rate
                creditsCandidates.append(start...max(end, mine.duration))
            }
        }

        return Result(
            // Mediana anche della fine: il confronto più lungo a volte va oltre
            // la sigla (due scene buie che si somigliano per caso, visto su
            // The Walking Dead), gli altri si fermano dove serve.
            introRange: consensus(of: introCandidates),
            creditsRange: consensus(of: creditsCandidates)
        )
    }

    /// Il confronto migliore tra le tracce dei due episodi: prima quelle nella
    /// stessa lingua, poi tutte le coppie (un doppiaggio da un'altra fonte non
    /// combacia, la traccia originale sì).
    nonisolated static func bestMatch(_ mine: [[UInt32]], _ myLanguages: [String],
                                      _ theirs: [[UInt32]], _ theirLanguages: [String],
                                      minSeconds: Double) -> AudioFingerprint.Match? {
        // Stessa lingua prima; se nessuna combacia, tutte le altre coppie
        // (tracce senza lingua, lingue segnate male).
        let all = mine.indices.flatMap { i in theirs.indices.map { (i, $0) } }
        let sameLanguage = all.filter { myLanguages[$0.0] == theirLanguages[$0.1] }
        var best: AudioFingerprint.Match?
        for group in [sameLanguage, all.filter { myLanguages[$0.0] != theirLanguages[$0.1] }] {
            for (i, j) in group {
                guard let match = AudioFingerprint.longestCommon(mine[i], theirs[j], minSeconds: minSeconds) else { continue }
                if match.covered > (best?.covered ?? 0) { best = match }
            }
            if best != nil { break }
        }
        return best
    }

    /// Con un solo episodio a disposizione non c'è altra scelta che fidarsi
    /// di quel singolo confronto. Con due o più, invece, preferisce il
    /// gruppo di intervalli che si sovrappongono tra loro (più episodi
    /// d'accordo sono un segnale più affidabile di un singolo match isolato,
    /// che potrebbe essere un abbaglio residuo) e ne restituisce la mediana
    /// dei bordi, così un singolo confronto leggermente sfalsato non tira
    /// il risultato tutto da una parte.
    private func consensus(of ranges: [ClosedRange<Double>], preferLongerEnd: Bool = false) -> ClosedRange<Double>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges[0] }

        var bestGroup: [ClosedRange<Double>] = []
        for candidate in ranges {
            let group = ranges.filter { $0.overlaps(candidate) }
            if group.count > bestGroup.count {
                bestGroup = group
            }
        }

        // Nessun accordo tra episodi diversi: meglio non mostrare nulla che
        // rischiare di piazzare il pulsante su un match isolato non confermato.
        guard bestGroup.count > 1 else { return nil }

        let lowers = bestGroup.map(\.lowerBound).sorted()
        let uppers = bestGroup.map(\.upperBound).sorted()
        let end = preferLongerEnd ? (uppers.last ?? 0) : median(uppers)
        return median(lowers)...max(end, median(lowers))
    }

    private func median(_ sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
