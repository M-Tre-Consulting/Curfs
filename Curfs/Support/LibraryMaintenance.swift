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
}
