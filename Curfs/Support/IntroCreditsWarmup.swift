//
//  IntroCreditsWarmup.swift
//  Curfs
//
//  All'avvio dell'app, in background e a bassa priorità, calcola e mette in
//  cache l'analisi "salta intro" per TUTTA la libreria locale. È la garanzia
//  che — dopo che l'app è stata aperta qualche minuto almeno una volta — il
//  pulsante compaia alla PRIMA riproduzione di qualunque episodio, invece di
//  dover rincorrere l'analisi mentre la sigla è già in corso.
//
//  Il lavoro pesante gira dentro `IntroCreditsAnalyzer.shared` (un actor), gli
//  episodi già in cache costano solo una lettura di un piccolo JSON.
//

import Foundation
import SwiftData

@MainActor
enum IntroCreditsWarmup {
    static func run(modelContext: ModelContext) async {
        // Lascia sfilare l'avvio e un eventuale import appena lanciato.
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }

        let episodes = ((try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? [])
            .filter { $0.kind == .episode && !$0.isRemote && $0.duration >= 90 }
        guard episodes.count > 1 else { return }

        // Priorità a ciò che l'utente probabilmente guarderà prima: ultimo
        // riprodotto / aggiunto di recente per primo.
        let ordered = episodes.sorted {
            ($0.lastPlayedAt ?? $0.dateAdded) > ($1.lastPlayedAt ?? $1.dateAdded)
        }

        for episode in ordered {
            if Task.isCancelled { return }
            let siblings = PlayerViewModel.siblingEpisodes(of: episode, in: episodes)
            guard !siblings.isEmpty else { continue }
            switch IntroCreditsAnalyzer.cacheStatus(for: episode, siblings: siblings) {
            case .readyWithIntro:
                IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: true)
                continue
            case .readyNoIntro:
                IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: false)
                continue
            case .missing:
                break
            }
            IntroAnalysisStatus.shared.begin(episode.id)
            let result = await IntroCreditsAnalyzer.shared.warm(item: episode, siblings: siblings)
            IntroAnalysisStatus.shared.finish(episode.id, foundIntro: result.introRange != nil)
        }
    }
}
