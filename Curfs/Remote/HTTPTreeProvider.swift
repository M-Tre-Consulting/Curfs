//
//  HTTPTreeProvider.swift
//  Curfs
//
//  Implementazione di RemoteContentProvider per un server HTTP statico che
//  espone una cartella di video con elenchi di directory in JSON (nginx:
//  `autoindex on; autoindex_format json;`). Nessun endpoint speciale lato
//  server: il provider cammina l'albero una volta per sessione e poi riusa
//  FileNameParser — le stesse euristiche dell'import da Files — per
//  ricostruire film / serie / stagioni / episodi.
//
//  Lo stesso URL diretto del file serve sia allo streaming (AVPlayer legge
//  il remoto con richieste Range) sia al download offline.
//

import Foundation

actor HTTPTreeProvider: RemoteContentProvider {

    private let baseURL: URL
    private let headers: [String: String]
    private let session: URLSession

    /// Cataloghi calcolati al primo accesso e tenuti per la vita del provider
    /// (ricreato solo quando cambia la configurazione della fonte).
    private var catalog: Catalog?
    private var buildTask: Task<Catalog, Error>?

    private struct Catalog {
        var titles: [RemoteTitle]
        var seasonsByTitleID: [String: [RemoteSeason]]
        /// id del titolo (film) o dell'episodio -> URL diretto del file.
        var fileURLByID: [String: URL]
        var fileExtByID: [String: String]
    }

    init(config: RemoteSourceConfig) {
        self.baseURL = config.baseURL ?? URL(string: "https://invalid.invalid")!
        self.headers = config.authHeaders

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = config.authHeaders
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - RemoteContentProvider

    func search(query: String) async throws -> [RemoteTitle] {
        let catalog = try await catalogEnsuringBuilt()
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return catalog.titles }
        return catalog.titles.filter { title in
            let haystack = title.name.lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    func seasons(for title: RemoteTitle) async throws -> [RemoteSeason] {
        let catalog = try await catalogEnsuringBuilt()
        return catalog.seasonsByTitleID[title.id] ?? []
    }

    func streamTarget(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteStreamTarget {
        let catalog = try await catalogEnsuringBuilt()
        guard let url = catalog.fileURLByID[episode?.id ?? title.id] else {
            throw RemoteProviderError.notConfigured
        }
        return RemoteStreamTarget(url: url, headers: headers)
    }

    func resolveDownload(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteDownloadTarget {
        let catalog = try await catalogEnsuringBuilt()
        let key = episode?.id ?? title.id
        guard let url = catalog.fileURLByID[key] else {
            throw RemoteProviderError.notConfigured
        }
        return RemoteDownloadTarget(
            fileURL: url,
            suggestedFileExtension: catalog.fileExtByID[key] ?? "mp4"
        )
    }

    // MARK: - Costruzione del catalogo (una volta, condivisa)

    private func catalogEnsuringBuilt() async throws -> Catalog {
        if let catalog { return catalog }
        if let buildTask { return try await buildTask.value }
        let task = Task { try await buildCatalog() }
        buildTask = task
        do {
            let built = try await task.value
            catalog = built
            buildTask = nil
            return built
        } catch {
            buildTask = nil
            throw error
        }
    }

    private func buildCatalog() async throws -> Catalog {
        let files = try await walk()
        guard !files.isEmpty else {
            return Catalog(titles: [], seasonsByTitleID: [:], fileURLByID: [:], fileExtByID: [:])
        }

        var classified = files.map { Self.classify($0, rootName: baseURL.lastPathComponent) }
        Self.resolveGroupsAndMovies(&classified)

        var titles: [RemoteTitle] = []
        var seasonsByTitleID: [String: [RemoteSeason]] = [:]
        var fileURLByID: [String: URL] = [:]
        var fileExtByID: [String: String] = [:]

        // Film
        for item in classified where item.kind == .movie {
            let id = "m|" + item.node.relativePath
            titles.append(RemoteTitle(
                id: id,
                name: item.title,
                kind: .movie,
                year: nil,
                posterURL: nil,
                overview: nil
            ))
            fileURLByID[id] = item.node.url
            fileExtByID[id] = item.node.fileExtension
        }

        // Serie: raggruppa per nome show
        let episodeItems = classified.filter { $0.kind == .episode }
        let byShow = Dictionary(grouping: episodeItems) { $0.showName ?? "Serie" }
        for (showName, items) in byShow {
            let titleID = "s|" + showName
            titles.append(RemoteTitle(
                id: titleID,
                name: showName,
                kind: .series,
                year: nil,
                posterURL: nil,
                overview: nil
            ))

            let bySeason = Dictionary(grouping: items) { $0.season ?? 1 }
            var seasons: [RemoteSeason] = []
            for (seasonNumber, seasonItems) in bySeason {
                let sorted = seasonItems.sorted { a, b in
                    let ea = a.episode ?? Int.max
                    let eb = b.episode ?? Int.max
                    if ea != eb { return ea < eb }
                    return a.node.name.localizedStandardCompare(b.node.name) == .orderedAscending
                }
                var episodes: [RemoteEpisode] = []
                for item in sorted {
                    let epID = "e|" + item.node.relativePath
                    episodes.append(RemoteEpisode(
                        id: epID,
                        number: item.episode ?? (episodes.count + 1),
                        title: item.title
                    ))
                    fileURLByID[epID] = item.node.url
                    fileExtByID[epID] = item.node.fileExtension
                }
                seasons.append(RemoteSeason(number: seasonNumber, episodes: episodes))
            }
            seasonsByTitleID[titleID] = seasons.sorted { $0.number < $1.number }
        }

        titles = await Self.withPosters(titles)
        titles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Catalog(
            titles: titles,
            seasonsByTitleID: seasonsByTitleID,
            fileURLByID: fileURLByID,
            fileExtByID: fileExtByID
        )
    }

    /// Risolve la locandina ufficiale di ogni titolo via `PosterFetcher`, a
    /// piccoli gruppi concorrenti (non un `TaskGroup` unico su tutto il
    /// catalogo: per una libreria grande sparerebbe decine di richieste a
    /// iTunes tutte insieme). Gira una volta sola per la vita del provider,
    /// insieme al resto della costruzione del catalogo.
    private static func withPosters(_ titles: [RemoteTitle]) async -> [RemoteTitle] {
        var result = titles
        let chunkSize = 6
        for start in stride(from: 0, to: titles.count, by: chunkSize) {
            let end = min(start + chunkSize, titles.count)
            await withTaskGroup(of: (Int, URL?).self) { group in
                for i in start..<end {
                    let title = titles[i]
                    group.addTask {
                        (i, await PosterFetcher.shared.posterURL(forName: title.name, kind: title.kind))
                    }
                }
                for await (i, poster) in group {
                    result[i].posterURL = poster
                }
            }
        }
        return result
    }

    // MARK: - Camminata dell'albero (elenchi JSON di nginx)

    private struct FileNode: Sendable {
        let name: String
        /// Componenti sotto la root: cartelle + nome file (ultimo elemento).
        let relativeComponents: [String]
        let url: URL

        var relativePath: String { relativeComponents.joined(separator: "/") }
        var folders: [String] { Array(relativeComponents.dropLast()) }
        var fileExtension: String {
            let ext = (name as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "mp4" : ext
        }
    }

    /// Voce di una directory come emessa da `autoindex_format json`.
    private struct DirEntry: Decodable {
        let name: String
        let type: String
    }

    private func walk() async throws -> [FileNode] {
        var results: [FileNode] = []
        var queue: [[String]] = [[]]          // liste di componenti-cartella da esplorare
        var visited = 0
        var isRootBatch = true
        let maxEntries = 8000
        let maxDepth = 8

        while !queue.isEmpty {
            let batch = queue
            queue.removeAll(keepingCapacity: true)
            let rootBatch = isRootBatch
            isRootBatch = false

            try await withThrowingTaskGroup(of: (relComponents: [String], entries: [DirEntry]).self) { group in
                for relComponents in batch {
                    group.addTask { [self] in
                        do {
                            return (relComponents, try await listDirectory(relComponents))
                        } catch {
                            // La radice deve segnalare l'errore (configurazione
                            // o credenziali sbagliate). Una sottocartella che
                            // non si lascia elencare viene semplicemente saltata.
                            if rootBatch { throw error }
                            return (relComponents, [])
                        }
                    }
                }
                for try await (relComponents, entries) in group {
                    for entry in entries {
                        let childComponents = relComponents + [entry.name]
                        if entry.type == "directory" {
                            if childComponents.count <= maxDepth {
                                queue.append(childComponents)
                            }
                        } else if FileNameParser.videoExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                            visited += 1
                            if visited <= maxEntries {
                                results.append(FileNode(
                                    name: entry.name,
                                    relativeComponents: childComponents,
                                    url: urlFor(childComponents)
                                ))
                            }
                        }
                    }
                }
            }
        }
        return results
    }

    private func listDirectory(_ relComponents: [String]) async throws -> [DirEntry] {
        var url = urlFor(relComponents)
        // nginx dà l'elenco solo con lo slash finale sulla directory.
        if !url.absoluteString.hasSuffix("/") {
            url = URL(string: url.absoluteString + "/") ?? url
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProviderError.notConfigured
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw RemoteProviderError.unauthorized
            }
            throw RemoteProviderError.server(status: http.statusCode)
        }
        // Se non è JSON (es. autoindex non in modalità json) l'elenco è inservibile.
        guard let entries = try? JSONDecoder().decode([DirEntry].self, from: data) else {
            throw RemoteProviderError.badListing
        }
        return entries
    }

    private func urlFor(_ relComponents: [String]) -> URL {
        var url = baseURL
        for component in relComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    // MARK: - Classificazione (specchio di ImportEngine, su dati remoti)

    private struct ClassifiedItem {
        let node: FileNode
        var kind: MediaKind
        var title: String
        var showName: String?
        var season: Int?
        var episode: Int?
    }

    private static let movieBuckets: Set<String> = [
        "film", "films", "movie", "movies", "cinema", "pellicole", "lungometraggi"
    ]
    private static let seriesBuckets: Set<String> = [
        "serie", "series", "serie tv", "serietv", "tv", "show", "shows", "telefilm", "tvshows"
    ]

    /// I nomi remoti arrivano spesso da "slug" di cartelle
    /// (`il-trono-di-spade`): trattini/underscore → spazi, spazi multipli
    /// compattati, iniziali maiuscole. Così il titolo mostrato somiglia a
    /// quello della libreria locale.
    private static func prettify(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty else { return raw }
        return spaced.capitalized
    }

    private static func classify(_ node: FileNode, rootName: String) -> ClassifiedItem {
        // Rimuove un'eventuale cartella "contenitore" di primo livello
        // (Film/, Serie/, ...) così non finisce per essere scambiata per il
        // nome di una serie.
        var folders = node.folders
        if let first = folders.first?.lowercased().trimmingCharacters(in: .whitespaces),
           movieBuckets.contains(first) || seriesBuckets.contains(first) {
            folders = Array(folders.dropFirst())
        }

        let filenameNoExt = (node.name as NSString).deletingPathExtension

        if let match = FileNameParser.extractSeasonEpisode(filenameNoExt) {
            let sIdx = FileNameParser.seasonFolderIndex(folders)
            let showFromFolder = folders.isEmpty
                ? nil
                : FileNameParser.bestShowName(folders: folders, seasonHintIndex: sIdx, rootFallback: rootName)
            let showFromFilename = FileNameParser.cleanTitle(FileNameParser.textBefore(match, in: filenameNoExt))
            let rawShowName = showFromFolder ?? (showFromFilename.isEmpty ? "Serie" : showFromFilename)

            let epTitle = FileNameParser.cleanEpisodeTitle(filenameNoExt)
            return ClassifiedItem(
                node: node,
                kind: .episode,
                title: epTitle.isEmpty ? "Episodio \(match.episode)" : prettify(epTitle),
                showName: prettify(rawShowName),
                season: match.season,
                episode: match.episode
            )
        }

        if !folders.isEmpty {
            let sIdx = FileNameParser.seasonFolderIndex(folders)
            let season = sIdx.flatMap { FileNameParser.seasonNumber(inFolderName: folders[$0]) } ?? 1
            let showName = FileNameParser.bestShowName(folders: folders, seasonHintIndex: sIdx, rootFallback: rootName)
            return ClassifiedItem(
                node: node,
                kind: .episode,
                title: prettify(FileNameParser.cleanTitle(filenameNoExt)),
                showName: prettify(showName),
                season: season,
                episode: nil
            )
        }

        return ClassifiedItem(
            node: node,
            kind: .movie,
            title: prettify(FileNameParser.cleanTitle(filenameNoExt)),
            showName: nil,
            season: nil,
            episode: nil
        )
    }

    /// Un gruppo show+stagione con un solo file non è una serie: torna film.
    /// Negli altri gruppi assegna i numeri di episodio mancanti dall'ordine
    /// dei nomi file.
    private static func resolveGroupsAndMovies(_ items: inout [ClassifiedItem]) {
        var groups: [String: [Int]] = [:]
        for (i, item) in items.enumerated() where item.kind == .episode && item.episode == nil {
            let key = "\(item.showName ?? "")|\(item.season ?? 1)"
            groups[key, default: []].append(i)
        }

        for (_, indices) in groups {
            if indices.count == 1 {
                let i = indices[0]
                items[i].kind = .movie
                items[i].title = FileNameParser.cleanTitle((items[i].node.name as NSString).deletingPathExtension)
                items[i].showName = nil
                items[i].season = nil
                items[i].episode = nil
            } else {
                let sorted = indices.sorted {
                    items[$0].node.name.localizedStandardCompare(items[$1].node.name) == .orderedAscending
                }
                for (n, idx) in sorted.enumerated() {
                    items[idx].episode = n + 1
                }
            }
        }
    }
}
