//
//  ProfileModels.swift
//  Curfs
//
//  Profili salvati sul server dell'utente, non sul dispositivo: così iPhone,
//  Mac e TV vedono lo stesso profilo e lo stesso minutaggio. Sul server, in
//  una cartella nascosta accanto ai video (nginx non la elenca, quindi non
//  finisce nel catalogo):
//
//    .curfs/profiles/<id>/profile.json   nome + versione della foto
//    .curfs/profiles/<id>/avatar.jpg     foto profilo (facoltativa)
//    .curfs/profiles/<id>/progress.json  minutaggio per episodio/film
//
//  Lo stesso formato lo legge e lo scrive l'app TV (`tv/app/js/profiles.js`):
//  se cambia qui, va cambiato anche lì.
//

import Foundation

struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Versione della foto (cambia a ogni nuova foto, per non vedere quella
    /// vecchia in cache). `nil` = nessuna foto.
    var avatar: Int?
    var created: Int64?

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// A che punto è un episodio o un film. `at` in millisecondi dal 1970 (come
/// `Date.now()` in JavaScript): a parità di chiave vince il più recente.
struct ProgressEntry: Codable, Equatable, Sendable {
    var pos: Double
    var dur: Double
    var done: Bool
    var at: Int64
    /// "episode" o "movie".
    var kind: String
    /// Titolo dell'episodio o del film.
    var title: String
    var show: String?
    var season: Int?
    var episode: Int?
    /// Percorso del file sul server (relativo alla radice, non codificato),
    /// se il video sta lì: un altro dispositivo che non ce l'ha in libreria
    /// lo aggiunge in streaming.
    var path: String?
}

struct ProgressFile: Codable, Sendable {
    var version = 1
    var entries: [String: ProgressEntry] = [:]

    /// Unisce `other` a questo: per ogni chiave resta la voce più recente
    /// (il percorso sul server non si perde se la più recente non lo conosce).
    mutating func merge(_ other: [String: ProgressEntry]) {
        for (key, incoming) in other {
            guard let existing = entries[key] else {
                entries[key] = incoming
                continue
            }
            if incoming.at > existing.at {
                var winner = incoming
                if winner.path == nil { winner.path = existing.path }
                entries[key] = winner
            } else if existing.path == nil, let path = incoming.path {
                entries[key]?.path = path
            }
        }
    }
}

/// Chiave con cui lo stesso episodio/film si riconosce su dispositivi diversi:
/// per nome (serie + stagione + episodio, o titolo del film), perché un
/// episodio importato da File non ha un percorso sul server. Nomi normalizzati
/// (minuscole, niente accenti, solo lettere e cifre, senza "(anno)" finale):
/// "Il Trono Di Spade" e "il-trono-di-spade" combaciano, "Game of Thrones" no.
/// Stessa funzione in `tv/app/js/profiles.js` (`syncKey`).
enum SyncKey {
    static func normalized(_ name: String) -> String {
        let noYear = name.replacingOccurrences(of: #"\s*\((19|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
        let folded = noYear.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func episode(show: String, season: Int, episode: Int) -> String {
        "e:\(normalized(show)):\(season):\(episode)"
    }

    static func movie(title: String) -> String {
        "m:\(normalized(title))"
    }

    static func key(for item: MediaItem) -> String? {
        switch item.kind {
        case .episode:
            guard let show = item.showName, let s = item.seasonNumber, let e = item.episodeNumber,
                  !normalized(show).isEmpty else { return nil }
            return episode(show: show, season: s, episode: e)
        case .movie:
            guard !normalized(item.title).isEmpty else { return nil }
            return movie(title: item.title)
        }
    }
}

extension Date {
    var millisecondsSince1970: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}
