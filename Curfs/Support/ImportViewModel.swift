//
//  ImportViewModel.swift
//  Curfs
//
//  Orchestratore lato UI dell'importazione: riceve gli URL scelti nel
//  document picker, delega il lavoro pesante a ImportEngine e salva i
//  risultati in SwiftData, tenendo la UI aggiornata sul progresso.
//

import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
final class ImportViewModel {
    var isImporting = false
    var progressCompleted = 0
    var progressTotal = 0
    var currentFileName = ""
    var lastError: String?

    private let engine = ImportEngine()

    func handlePicked(urls: [URL], modelContext: ModelContext) {
        guard !urls.isEmpty else { return }

        var accessedURLs: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
        guard !accessedURLs.isEmpty else {
            lastError = "Non riesco ad accedere ai file selezionati."
            return
        }

        isImporting = true
        progressCompleted = 0
        progressTotal = 0
        currentFileName = ""

        Task {
            defer {
                for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                isImporting = false
            }

            let items = await engine.importURLs(urls) { [weak self] update in
                Task { @MainActor in
                    self?.progressCompleted = update.completed
                    self?.progressTotal = update.total
                    self?.currentFileName = update.currentName
                }
            }

            guard !items.isEmpty else {
                lastError = "Nessun video valido trovato nella selezione."
                return
            }

            var insertedEpisodes: [MediaItem] = []
            for imported in items {
                let mediaItem = MediaItem(
                    title: imported.title,
                    kind: imported.kind,
                    showName: imported.showName,
                    seasonNumber: imported.season,
                    episodeNumber: imported.episode,
                    relativePath: imported.relativePath,
                    duration: imported.duration
                )
                modelContext.insert(mediaItem)
                await ThumbnailGenerator.generateIfNeeded(for: mediaItem)
                if mediaItem.kind == .episode { insertedEpisodes.append(mediaItem) }
            }
            try? modelContext.save()

            warmIntroDetection(for: insertedEpisodes, modelContext: modelContext)
        }
    }

    /// Dopo l'import, in background e a bassa priorità, pre-calcola l'analisi
    /// "salta intro" per gli episodi appena aggiunti: così al primo play il
    /// pulsante è già pronto invece di comparire (o no) a sigla iniziata.
    private func warmIntroDetection(for episodes: [MediaItem], modelContext: ModelContext) {
        guard !episodes.isEmpty else { return }
        let library = (try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? episodes
        Task(priority: .background) {
            for episode in episodes {
                if Task.isCancelled { return }
                let siblings = PlayerViewModel.siblingEpisodes(of: episode, in: library)
                guard !siblings.isEmpty else { continue }
                IntroAnalysisStatus.shared.begin(episode.id)
                let result = await IntroCreditsAnalyzer.shared.warm(item: episode, siblings: siblings)
                IntroAnalysisStatus.shared.finish(episode.id, foundIntro: result.introRange != nil)
            }
        }
    }
}
