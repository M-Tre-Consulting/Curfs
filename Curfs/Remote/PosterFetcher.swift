//
//  PosterFetcher.swift
//  Curfs
//
//  Locandine ufficiali per i titoli della sezione Cerca: interroga l'API di
//  ricerca di iTunes (pubblica, nessuna chiave/account richiesti) dato il
//  nome del film/serie e restituisce l'URL dell'artwork, ingrandito rispetto
//  alla miniatura 100x100 di default. `RemoteTitle.posterURL` era già usato
//  da `SearchResultCard`/`RemoteTitleDetailView` (AsyncImage) — mancava solo
//  chi lo valorizzasse: vedi `HTTPTreeProvider.buildCatalog`.
//
//  NB: `media=movie` come parametro della query iTunes restituisce
//  sistematicamente 0 risultati (comportamento osservato, non documentato né
//  garantito da Apple) — la ricerca va fatta senza filtro `media`/`entity` e
//  il tipo giusto selezionato lato client dal campo `kind` di ogni risultato.
//
//  Risultati (trovati E non trovati) tenuti in cache su disco per non
//  re-interrogare a ogni ricostruzione del catalogo (pull-to-refresh,
//  riavvio app). Cache in Caches/, non Application Support: perderla non è
//  un problema, si ricalcola da sola alla prossima ricerca (stesso
//  ragionamento di `fingerprintsDirectory`, vedi LibraryStorage).
//

import Foundation

actor PosterFetcher {
    static let shared = PosterFetcher()

    /// "" = già cercato, nessun risultato utile (evita di riprovare ad ogni
    /// ricostruzione del catalogo per un titolo che iTunes non ha).
    private var cache: [String: String] = [:]
    private var cacheLoaded = false

    private struct SearchResponse: Decodable {
        var results: [Item] = []
        struct Item: Decodable {
            var kind: String?
            var artworkUrl100: String?
        }
    }

    func posterURL(forName name: String, kind: RemoteTitleKind) async -> URL? {
        await loadCacheIfNeeded()
        let key = cacheKey(name: name, kind: kind)
        if let cached = cache[key] {
            return cached.isEmpty ? nil : URL(string: cached)
        }
        let resolved = await fetch(name: name, kind: kind)
        cache[key] = resolved?.absoluteString ?? ""
        saveCache()
        return resolved
    }

    private func fetch(name: String, kind: RemoteTitleKind) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return nil }

        let wantedKinds: Set<String> = kind == .movie
            ? ["feature-movie"]
            : ["tv-episode", "tv-season"]
        guard let match = decoded.results.first(where: { wantedKinds.contains($0.kind ?? "") }),
              let artwork = match.artworkUrl100
        else { return nil }
        return URL(string: upsized(artwork))
    }

    /// L'artwork di default è 100x100 (o più piccolo): sostituisce le
    /// dimensioni nel path con una risoluzione da locandina vera.
    private func upsized(_ artworkUrl100: String) -> String {
        for size in ["100x100bb", "60x60bb", "30x30bb"] where artworkUrl100.contains(size) {
            return artworkUrl100.replacingOccurrences(of: size, with: "600x900bb")
        }
        return artworkUrl100
    }

    private func cacheKey(name: String, kind: RemoteTitleKind) -> String {
        "\(kind.rawValue)|\(name.lowercased())"
    }

    // MARK: - Cache su disco

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "RemotePosters.json")
    }

    private func loadCacheIfNeeded() async {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        cache = decoded
    }

    private func saveCache() {
        let snapshot = cache
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.cacheFileURL, options: .atomic)
        }
    }
}
