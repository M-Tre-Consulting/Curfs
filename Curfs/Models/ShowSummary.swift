//
//  ShowSummary.swift
//  Curfs
//
//  Raggruppamento "virtuale" (non persistito) degli episodi di una stessa
//  serie, calcolato al volo dagli MediaItem in libreria.
//

import Foundation

struct ShowSummary: Identifiable {
    var id: String { name }
    let name: String
    let episodes: [MediaItem]

    var sortedEpisodes: [MediaItem] {
        episodes.sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }
    }

    var seasons: [Int] {
        Array(Set(episodes.compactMap(\.seasonNumber))).sorted()
    }

    var episodeCount: Int { episodes.count }

    /// Serie composta solo da voci in streaming (nessun file scaricato).
    var isStreaming: Bool { !episodes.isEmpty && episodes.allSatisfy(\.isRemote) }

    /// Il prossimo episodio da guardare: se c'è un episodio lasciato a metà,
    /// riprende quello (il più recente per data di ultima riproduzione, non
    /// il primo in ordine — altrimenti se si è già avanti con la visione,
    /// "Riprendi" punterebbe erroneamente a un episodio precedente mai
    /// finito). Senza episodi in corso, va al primo mai iniziato in ordine,
    /// oppure all'ultimo se sono già tutti finiti.
    var nextToWatch: MediaItem? {
        let inProgress = episodes.filter { $0.hasProgress }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
        return inProgress ?? sortedEpisodes.first { !$0.isFinished } ?? sortedEpisodes.last
    }

    var posterItem: MediaItem? { nextToWatch ?? sortedEpisodes.first }

    var displayProgress: Double { nextToWatch?.progressFraction ?? 0 }

    var latestAdded: Date { episodes.map(\.dateAdded).max() ?? .distantPast }

    static func groups(from items: [MediaItem]) -> [ShowSummary] {
        let episodes = items.filter { $0.kind == .episode }
        // Se lo stesso episodio esiste sia scaricato sia come voce streaming,
        // tieni quello locale e scarta il doppione remoto.
        let localKeys = Set(episodes.filter { !$0.isRemote }.map(episodeKey))
        let deduped = episodes.filter { !$0.isRemote || !localKeys.contains(episodeKey($0)) }
        let byShow = Dictionary(grouping: deduped) { $0.showName ?? "Serie" }
        return byShow.map { ShowSummary(name: $0.key, episodes: $0.value) }
            .sorted { $0.latestAdded > $1.latestAdded }
    }

    private static func episodeKey(_ item: MediaItem) -> String {
        "\(item.showName ?? "")|\(item.seasonNumber ?? 0)|\(item.episodeNumber ?? 0)"
    }
}
