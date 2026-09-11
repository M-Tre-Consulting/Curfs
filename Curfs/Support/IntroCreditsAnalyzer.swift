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
    static let analysisVersion = 8

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

    /// Cancella TUTTA la cache su disco di sigla/coda (impronte + risultati,
    /// stesso posto per entrambe: `LibraryStorage.fingerprintsDirectory`) —
    /// usata dal tasto manuale "Ricalcola" in `ShowDetailView` quando l'utente
    /// non si fida del risultato mostrato. Il sistema si ripara già da solo
    /// nel tempo (ogni pezzo mancante si ricalcola quando serve), ma un modo
    /// per forzarlo SUBITO, senza aspettare, resta comunque utile.
    nonisolated static func resetDiskCache() {
        let dir = LibraryStorage.fingerprintsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Distanza di Hamming massima (su 64 bit) perché due fotogrammi contino
    /// come "lo stesso fotogramma". Tenuta stretta (invece che permissiva)
    /// per non confondere due scene semplicemente simili con un vero
    /// fotogramma in comune.
    private let matchThreshold = 8
    /// Durata minima del tratto combaciante perché conti come sigla/coda:
    /// abbastanza da escludere match brevi e casuali (es. un singolo stacco
    /// simile), ma sotto la durata reale di qualunque sigla/coda vera.
    private let minMatchSeconds: Double = 12
    /// Massimo sfalsamento temporale cercato tra i due episodi. Ampio: la
    /// sigla del PRIMO episodio può partire minuti dopo rispetto agli altri
    /// (cold open lungo), quindi lo sfalsamento da recuperare è grande. Deve
    /// coprire almeno quanto `maxIntroWindow` in FingerprintExtractor (8 min),
    /// altrimenti la sigla dell'ep. 1 verrebbe comunque campionata ma non
    /// più cercata a quella distanza. Il costo della ricerca resta
    /// trascurabile (poche centinaia di migliaia di confronti di bit).
    private let maxShift: Double = 480

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

            if let range = matchRange(mine: mine.introSamples, theirs: theirs.introSamples) {
                introCandidates.append(range)
            }
            if let range = matchRange(mine: mine.creditsSamples, theirs: theirs.creditsSamples) {
                // I campioni "credits" sono indicizzati come distanza dalla
                // fine: li riportiamo al tempo assoluto dell'episodio corrente.
                let duration = mine.duration
                creditsCandidates.append((duration - range.upperBound)...(duration - range.lowerBound))
            }
        }

        return Result(
            // Per la sigla il bordo finale è meglio prenderlo lungo: un run più
            // corto è una SOTTO-rilevazione (la coda non confrontabile —
            // dissolvenze, cartello col titolo — spezza il tratto prima), non un
            // falso positivo. Per i titoli di coda resta la mediana.
            introRange: consensus(of: introCandidates, preferLongerEnd: true),
            creditsRange: consensus(of: creditsCandidates)
        )
    }

    /// Cerca lo sfalsamento che massimizza il numero di fotogrammi
    /// combacianti tra le due sequenze, poi trova il tratto continuo più
    /// lungo di match a quello sfalsamento (tollerando un paio di buchi, per
    /// non spezzare il tratto su qualche fotogramma di transizione).
    private func matchRange(mine: [FrameSample], theirs: [FrameSample]) -> ClosedRange<Double>? {
        guard mine.count > 1, !theirs.isEmpty else { return nil }

        // Passo di campionamento reale, dedotto dai dati: serve a convertire
        // "numero di campioni" in secondi in modo coerente col campionamento
        // usato dall'estrattore, qualunque esso sia.
        let spacing = max(0.5, mine[1].time - mine[0].time)

        var theirsByTime: [Double: UInt64] = [:]
        for sample in theirs { theirsByTime[sample.time.rounded()] = sample.hash }
        func theirHash(near time: Double) -> UInt64? { theirsByTime[time.rounded()] }

        var bestShift = 0.0
        var bestScore = 0
        var shift = -maxShift
        while shift <= maxShift {
            var score = 0
            for sample in mine {
                if let theirHash = theirHash(near: sample.time - shift),
                   FrameHasher.hammingDistance(sample.hash, theirHash) <= matchThreshold {
                    score += 1
                }
            }
            if score > bestScore { bestScore = score; bestShift = shift }
            shift += 1
        }

        guard Double(bestScore) * spacing >= minMatchSeconds else { return nil }

        var runs: [[Double]] = []
        var current: [Double] = []
        var misses = 0
        for sample in mine.sorted(by: { $0.time < $1.time }) {
            let matched: Bool
            if let theirHash = theirHash(near: sample.time - bestShift) {
                matched = FrameHasher.hammingDistance(sample.hash, theirHash) <= matchThreshold
            } else {
                matched = false
            }
            if matched {
                current.append(sample.time)
                misses = 0
            } else {
                misses += 1
                if misses > 2 {
                    if !current.isEmpty { runs.append(current) }
                    current = []
                }
            }
        }
        if !current.isEmpty { runs.append(current) }

        guard let run = runs.max(by: { $0.count < $1.count }),
              let start = run.first, let end = run.last,
              end - start >= minMatchSeconds else { return nil }
        // L'ultimo campione combaciante è `end`, ma la sigla finisce da
        // qualche parte tra lì e il campione successivo: estendiamo di un
        // passo così il salto atterra appena DENTRO l'episodio, non un attimo
        // prima della fine della sigla.
        return start...(end + spacing)
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
