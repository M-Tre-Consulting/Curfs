//
//  IntroAnalysisQueue.swift
//  Curfs
//
//  Coda UNICA, a livello di app, dell'analisi "salta intro" degli episodi
//  locali. Tutti i punti che vogliono l'analisi (avvio app, import da File,
//  download dal server, apertura di una stagione, episodio successivo nel
//  player) si limitano ad accodare degli episodi: il lavoro lo fa un solo
//  worker in background che NON dipende da nessuna schermata.
//
//  Prima ogni schermata faceva girare la propria analisi dentro un `.task`
//  di SwiftUI: uscendo dalla stagione o cambiandola il task veniva
//  cancellato a metà di un episodio, e quell'episodio finiva in cache come
//  "analizzato, nessuna sigla" (impronte parziali + risultato vuoto) — uno
//  "bruciato" a ogni uscita, fino a far fallire l'intera stagione. Qui una
//  schermata può solo cambiare l'ORDINE della coda (la stagione che stai
//  guardando passa davanti), mai interrompere l'episodio in corso.
//
//  Un episodio alla volta, di proposito: l'analizzatore e l'estrattore sono
//  actor (le analisi in parallelo si metterebbero comunque in fila lì) e
//  due analisi contemporanee finirebbero per decodificare gli stessi
//  episodi vicini due volte.
//

import Foundation
import SwiftData

@MainActor
final class IntroAnalysisQueue {
    static let shared = IntroAnalysisQueue()
    private init() {}

    private var pending: [UUID] = []
    private var worker: Task<Void, Never>?
    /// > 0 mentre "Ricalcola" sta svuotando la cache: il worker non riparte
    /// finché i file non sono stati cancellati.
    private var resetting = 0

    private var context: ModelContext { AppModelContainer.shared.mainContext }

    /// Tutta la libreria locale (avvio app): ultimo riprodotto/aggiunto prima.
    func enqueueLibrary() {
        let ordered = localEpisodes().sorted {
            ($0.lastPlayedAt ?? $0.dateAdded) > ($1.lastPlayedAt ?? $1.dateAdded)
        }
        enqueue(ordered.map(\.id))
    }

    /// Tutti gli episodi delle serie indicate, dopo un import o un download:
    /// un episodio nuovo cambia anche i vicini (e quindi la cache) di quelli
    /// già presenti. `first` = gli episodi appena arrivati, analizzati per primi.
    func enqueueShows(_ names: Set<String>, first: [UUID] = []) {
        let episodes = localEpisodes()
            .filter { names.contains($0.showName ?? "") }
            .sorted {
                (($0.seasonNumber ?? 0), ($0.episodeNumber ?? 0)) < (($1.seasonNumber ?? 0), ($1.episodeNumber ?? 0))
            }
        enqueue(first + episodes.map(\.id))
    }

    /// Porta in testa alla coda questi episodi (es. la stagione aperta): quelli
    /// già in cache vengono segnati subito come pronti, così l'indicatore è
    /// giusto anche se il worker sta ancora finendo un episodio di un'altra serie.
    func prioritize(_ episodes: [MediaItem]) {
        let library = localEpisodes()
        var toAnalyze: [UUID] = []
        for episode in episodes where !episode.isRemote {
            let siblings = PlayerViewModel.siblingEpisodes(of: episode, in: library)
            guard !siblings.isEmpty else { continue }
            switch IntroCreditsAnalyzer.cacheStatus(for: episode, siblings: siblings) {
            case .readyWithIntro: IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: true)
            case .readyNoIntro: IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: false)
            case .missing: toAnalyze.append(episode.id)
            }
        }
        enqueue(toAnalyze, urgent: true)
    }

    /// Tasto "Ricalcola": cancella cache e stato SOLO di questi episodi e li
    /// rianalizza per primi. Aspetta che l'episodio eventualmente in corso si
    /// fermi prima di cancellare i file, così non può riscriverli subito dopo.
    func recompute(_ ids: [UUID]) async {
        resetting += 1
        if let old = worker {
            worker = nil
            old.cancel()
            await old.value
        }
        IntroCreditsAnalyzer.resetDiskCache(for: ids)
        IntroAnalysisStatus.shared.reset(ids)
        resetting -= 1
        enqueue(ids, urgent: true)
    }

    func enqueue(_ ids: [UUID], urgent: Bool = false) {
        guard !ids.isEmpty else { return }
        if urgent {
            var seen = Set<UUID>()
            let front = ids.filter { seen.insert($0).inserted }
            pending.removeAll { seen.contains($0) }
            pending.insert(contentsOf: front, at: 0)
        } else {
            var known = Set(pending)
            for id in ids where known.insert(id).inserted {
                pending.append(id)
            }
        }
        startIfNeeded()
    }

    // MARK: Worker

    private func startIfNeeded() {
        guard worker == nil, resetting == 0, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, !pending.isEmpty {
            let id = pending.removeFirst()
            await process(id)
        }
        // Se cancellato, `recompute` ha già tolto il riferimento (e potrebbe
        // averne avviato un altro): non va toccato.
        if !Task.isCancelled { worker = nil }
    }

    private func process(_ id: UUID) async {
        let library = localEpisodes()
        guard let episode = library.first(where: { $0.id == id }) else { return }
        let siblings = PlayerViewModel.siblingEpisodes(of: episode, in: library)
        guard !siblings.isEmpty else { return }

        switch IntroCreditsAnalyzer.cacheStatus(for: episode, siblings: siblings) {
        case .readyWithIntro:
            IntroAnalysisStatus.shared.markCached(id, foundIntro: true)
            return
        case .readyNoIntro:
            IntroAnalysisStatus.shared.markCached(id, foundIntro: false)
            return
        case .missing:
            break
        }
        // Durata non ancora misurata: l'analisi uscirebbe senza fare nulla.
        // Ci riprova il player (`onDurationResolved`) o il prossimo avvio.
        guard episode.duration >= 90 else { return }

        IntroAnalysisStatus.shared.begin(id)
        let result = await IntroCreditsAnalyzer.shared.warm(item: episode, siblings: siblings)
        if Task.isCancelled {
            // Interrotto da "Ricalcola": nulla è stato salvato, torna in coda.
            IntroAnalysisStatus.shared.abandon(id)
            pending.insert(id, at: 0)
            return
        }
        IntroAnalysisStatus.shared.finish(id, foundIntro: result.introRange != nil)
    }

    private func localEpisodes() -> [MediaItem] {
        ((try? context.fetch(FetchDescriptor<MediaItem>())) ?? [])
            .filter { $0.kind == .episode && !$0.isRemote }
    }
}
