//
//  LibraryMaintenance.swift
//  Curfs
//
//  Operazioni di pulizia sulla libreria: eliminare un film o un'intera
//  serie rimuove sia il record che il file video e la miniatura dal disco.
//

import Foundation
import SwiftData

enum LibraryMaintenance {
    static func delete(_ item: MediaItem, modelContext: ModelContext) {
        // Un item in streaming non ha file locali (e `fileURL` punterebbe
        // alla cartella Library stessa): si cancella solo il record.
        if !item.isRemote {
            try? FileManager.default.removeItem(at: item.fileURL)
            try? FileManager.default.removeItem(at: item.thumbnailURL)
        }
        modelContext.delete(item)
        try? modelContext.save()
    }

    static func deleteShow(_ show: ShowSummary, modelContext: ModelContext) {
        for episode in show.episodes {
            delete(episode, modelContext: modelContext)
        }
    }

    /// Elimina solo gli episodi di una stagione, lasciando intatte le altre.
    static func deleteSeason(_ season: Int, of show: ShowSummary, modelContext: ModelContext) {
        for episode in show.episodes where (episode.seasonNumber ?? 1) == season {
            delete(episode, modelContext: modelContext)
        }
    }

    /// Ripara retroattivamente `MediaItem.remoteOriginFlag` per gli item
    /// scaricati PRIMA che quel flag esistesse: a quella data
    /// `RemoteDownloadManager.finalize` creava un `MediaItem` locale
    /// indistinguibile da un import da Files, quindi non c'è modo di saperlo
    /// con certezza dal solo record — si va per nome, confrontando showName
    /// (serie) / title (film) col catalogo remoto attuale. Best-effort: se
    /// nel frattempo hai salvato un episodio sotto un nome di serie diverso
    /// da quello del Pi (vedi "Salva in:"/`effectiveShowName`), quello non
    /// verrà riconosciuto — va segnato a mano riscaricandone un episodio.
    /// Restituisce quanti item sono stati corretti.
    @discardableResult
    static func backfillRemoteOrigin(catalog: [RemoteTitle], modelContext: ModelContext) -> Int {
        let seriesNames = Set(catalog.filter { $0.kind == .series }.map { $0.name.lowercased() })
        let movieNames = Set(catalog.filter { $0.kind == .movie }.map { $0.name.lowercased() })
        guard !seriesNames.isEmpty || !movieNames.isEmpty else { return 0 }

        let items = (try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? []
        var fixed = 0
        for item in items where !item.isRemote && item.remoteOriginFlag != true {
            switch item.kind {
            case .episode:
                guard let show = item.showName?.lowercased(), seriesNames.contains(show) else { continue }
            case .movie:
                guard movieNames.contains(item.title.lowercased()) else { continue }
            }
            item.remoteOriginFlag = true
            fixed += 1
        }
        if fixed > 0 { try? modelContext.save() }
        return fixed
    }
}
