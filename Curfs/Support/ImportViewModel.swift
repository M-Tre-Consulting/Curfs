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
            lastError = String(localized: "Non riesco ad accedere ai file selezionati.")
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
                lastError = String(localized: "Nessun video valido trovato nella selezione.")
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

            // Subito in background, per TUTTI gli episodi delle serie toccate
            // (i nuovi prima): non serve aprire la stagione e aspettare lì.
            IntroAnalysisQueue.shared.enqueueShows(
                Set(insertedEpisodes.compactMap(\.showName)),
                first: insertedEpisodes.map(\.id)
            )
        }
    }
}
