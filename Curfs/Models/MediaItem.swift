//
//  MediaItem.swift
//  Curfs
//
//  Modello persistito con SwiftData per un file video importato:
//  può essere un Film oppure un Episodio di una Serie (show + stagione + episodio).
//

import Foundation
import SwiftData

enum MediaKind: String, Codable, Sendable {
    case movie
    case episode
}

@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID

    var title: String
    var kindRaw: String

    // Solo per episodi
    var showName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?

    /// Percorso relativo alla cartella Library dei documenti dell'app.
    /// Vuoto per un item riprodotto in streaming dal server remoto (che non
    /// ha un file locale): vedi `remoteURLString`.
    var relativePath: String

    /// Se valorizzato, l'item è in streaming: `playbackURL` punta qui e non
    /// esiste alcun file locale. Attributo opzionale ⇒ migrazione SwiftData
    /// automatica, la libreria già sul dispositivo resta intatta.
    var remoteURLString: String?

    var duration: Double
    var playbackPosition: Double
    var isFinished: Bool

    var dateAdded: Date
    var lastPlayedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        kind: MediaKind,
        showName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        relativePath: String,
        remoteURLString: String? = nil,
        duration: Double = 0,
        playbackPosition: Double = 0,
        isFinished: Bool = false,
        dateAdded: Date = .now,
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.kindRaw = kind.rawValue
        self.showName = showName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.relativePath = relativePath
        self.remoteURLString = remoteURLString
        self.duration = duration
        self.playbackPosition = playbackPosition
        self.isFinished = isFinished
        self.dateAdded = dateAdded
        self.lastPlayedAt = lastPlayedAt
    }
}

extension MediaItem {
    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .movie }
        set { kindRaw = newValue.rawValue }
    }

    /// `true` per un item in streaming dal server remoto (nessun file locale).
    var isRemote: Bool { remoteURLString != nil }

    /// Percorso del file locale importato. Non ha senso per gli item remoti
    /// (relativePath vuoto) — usare `playbackURL` per la riproduzione e
    /// controllare `isRemote` prima di toccare il filesystem.
    var fileURL: URL {
        LibraryStorage.mediaDirectory.appending(path: relativePath)
    }

    /// URL da dare ad `AVPlayer`: il remoto se in streaming, altrimenti il
    /// file locale.
    var playbackURL: URL {
        if let remoteURLString, let url = URL(string: remoteURLString) { return url }
        return fileURL
    }

    var thumbnailURL: URL {
        LibraryStorage.thumbnailsDirectory.appending(path: "\(id.uuidString).jpg")
    }

    /// Frazione 0...1 di quanto è stato guardato.
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(playbackPosition / duration, 0), 1)
    }

    /// Compare in "Continua a guardare" dopo 1 minuto di riproduzione (utile
    /// per i film, dove il 2% da solo richiederebbe diversi minuti), oppure
    /// prima se il video è corto e il 2% arriva prima di 1 minuto.
    var hasProgress: Bool {
        guard !isFinished else { return false }
        return playbackPosition >= 60 || progressFraction > 0.02
    }

    var episodeCode: String? {
        guard kind == .episode, let s = seasonNumber, let e = episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    var subtitle: String? {
        guard kind == .episode else { return nil }
        if let code = episodeCode {
            return "\(code) · \(title)"
        }
        return title
    }
}
