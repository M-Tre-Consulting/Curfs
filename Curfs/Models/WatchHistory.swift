//
//  WatchHistory.swift
//  Curfs
//
//  "Riprendi" e Contenuti recenti (2026-11-28).
//
//  Riprendi = come la TV (`continueTarget`/`resumeTarget` in tv/app/js/app.js):
//  l'ultimo episodio TOCCATO della serie (per `lastPlayedAt`, finito o no);
//  se è finito si passa al successivo in ordine, altrimenti si riprende lui.
//  Prima si cercava "l'ultimo lasciato a metà": con un episodio vecchio mai
//  finito (es. chiuso durante i titoli di coda) e quelli dopo già visti su
//  un altro dispositivo, l'iPhone riproponeva quello vecchio (segnalato sul
//  profilo di Susi: TV a S7E2, iPhone fermo alla stagione 6).
//

import Foundation

enum ResumeLogic {
    /// - Parameter ordered: episodi in ordine (stagione, episodio).
    /// - Returns: l'elemento da guardare e se è "il prossimo" dopo uno finito.
    static func target<T>(in ordered: [T], lastPlayed: (T) -> Date?, isFinished: (T) -> Bool) -> (item: T, isNext: Bool)? {
        guard !ordered.isEmpty else { return nil }
        var latestIndex: Int?
        var latestDate = Date.distantPast
        for (i, element) in ordered.enumerated() {
            if let date = lastPlayed(element), date > latestDate {
                latestDate = date
                latestIndex = i
            }
        }
        guard let i = latestIndex else {
            // Mai guardato niente: il primo non finito, o il primo.
            return (ordered.first { !isFinished($0) } ?? ordered[0], false)
        }
        if isFinished(ordered[i]), i + 1 < ordered.count {
            return (ordered[i + 1], true)
        }
        return (ordered[i], false)
    }
}

/// Un titolo nei Contenuti recenti: una serie (i suoi episodi disponibili)
/// o un film.
struct RecentTitle: Identifiable {
    enum Kind { case series, movie }

    let id: String
    let kind: Kind
    let name: String
    /// Episodi disponibili (scaricati, o in streaming e ancora sul server),
    /// in ordine; per un film un solo elemento.
    let items: [MediaItem]
    /// Ultima attività: visione più recente, o download/import per ciò che
    /// non è mai stato guardato.
    let lastActivity: Date

    var movie: MediaItem? { kind == .movie ? items.first : nil }

    /// Da riprendere (vedi `ResumeLogic`). Per una serie il "prossimo" può
    /// non essere in libreria: allora resta l'ultimo visto (la scheda della
    /// serie, che conosce il catalogo, trova quello giusto).
    var resume: (item: MediaItem, isNext: Bool)? {
        ResumeLogic.target(in: items, lastPlayed: \.lastPlayedAt, isFinished: \.isFinished)
    }

    var downloadState: DownloadState {
        let local = items.filter { !$0.isRemote }.count
        if local == 0 { return .streaming }
        return local == items.count ? .downloaded : .partial
    }

    enum DownloadState { case downloaded, partial, streaming }

    var hasRemoteOrigin: Bool { items.contains(where: \.isRemoteOrigin) }

    /// - Parameter isAvailable: `false` per le voci in streaming il cui
    ///   file non c'è più sul server (vedi `ServerAvailability`): non
    ///   compaiono, e una serie senza episodi rimasti sparisce.
    static func build(from all: [MediaItem], isAvailable: (MediaItem) -> Bool) -> [RecentTitle] {
        let available = all.filter(isAvailable)
        var result: [RecentTitle] = []

        for show in ShowSummary.groups(from: available) {
            let episodes = show.sortedEpisodes
            guard let activity = activity(of: episodes) else { continue }
            result.append(RecentTitle(id: "s|" + show.name, kind: .series, name: show.name,
                                      items: episodes, lastActivity: activity))
        }

        let movies = available.filter { $0.kind == .movie }
        let localTitles = Set(movies.filter { !$0.isRemote }.map { $0.title.lowercased() })
        for movie in movies where !movie.isRemote || !localTitles.contains(movie.title.lowercased()) {
            guard let activity = activity(of: [movie]) else { continue }
            result.append(RecentTitle(id: "m|" + movie.id.uuidString, kind: .movie, name: movie.title,
                                      items: [movie], lastActivity: activity))
        }
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Guardato almeno una volta, oppure scaricato/importato (così ciò che
    /// è sul dispositivo si ritrova anche offline). Le voci in streaming
    /// solo "aggiunte" e mai aperte non sono un contenuto recente: stanno
    /// nella Libreria del server.
    private static func activity(of items: [MediaItem]) -> Date? {
        let watched = items.compactMap(\.lastPlayedAt).max()
        let downloaded = items.filter { !$0.isRemote }.map(\.dateAdded).max()
        return [watched, downloaded].compactMap { $0 }.max()
    }
}
