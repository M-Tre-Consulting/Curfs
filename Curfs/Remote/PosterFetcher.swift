//
//  PosterFetcher.swift
//  Curfs
//
//  Locandine ufficiali per i titoli della sezione Cerca, senza chiavi né
//  account:
//   1. Wikipedia RICONOSCE il titolo (anche italiano: "Oceania" → voce
//      inglese "Moana (2026 film)"), vedi `wikiIdentify`;
//   2. IMDb dà la locandina in alta risoluzione di quel titolo (~1000 px),
//      vedi `fetchIMDb`. Le locandine di Wikipedia sono di proposito
//      piccole (~250×380, regola sul fair use delle immagini non libere):
//      su una card Retina si vedevano sgranate;
//   3. se IMDb non trova/risponde, la locandina piccola di Wikipedia;
//   4. infine iTunes, che per i FILM è quasi inservibile (a settembre 2026
//      non trova nemmeno "Inception" o "The Matrix", e ogni filtro per film
//      restituisce 0 risultati) ma per le serie funziona bene. L'artwork
//      iTunes viene ingrandito rispetto alla miniatura 100x100 di default. `RemoteTitle.posterURL` era già usato
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
//  Un risultato iTunes viene accettato SOLO se il suo titolo combacia con
//  quello cercato: la ricerca di iTunes è larghissima e restituisce quasi
//  sempre *qualche* film (es. "Oceania" → "The Burned Barns", "Moana" →
//  "A Minecraft Movie"), quindi prendere il primo risultato del tipo giusto
//  dava copertine a caso per i titoli che iTunes non ha.
//
//  Copertine dell'utente: se sul server c'è un file poster accanto al
//  contenuto (vedi `HTTPTreeProvider`), vince su iTunes. La mappa
//  `overrides` viene SOSTITUITA per intero a ogni costruzione del catalogo,
//  così una copertina sparisce da sola quando il contenuto viene tolto dal
//  server; è salvata su disco solo perché la libreria la mostri anche prima
//  che il catalogo remoto sia stato caricato in questa sessione.
//

import Foundation

actor PosterFetcher {
    static let shared = PosterFetcher()

    /// "" = già cercato, nessun risultato utile (evita di riprovare ad ogni
    /// ricostruzione del catalogo per un titolo che iTunes non ha).
    private var cache: [String: String] = [:]
    /// Copertine dell'utente trovate sul server: chiave come `cache`.
    private var overrides: [String: String] = [:]
    private var cacheLoaded = false

    private struct SearchResponse: Decodable {
        var results: [Item] = []
        struct Item: Decodable {
            var kind: String?
            var artworkUrl100: String?
            var trackName: String?
            var collectionName: String?
            var artistName: String?
        }
    }

    func posterURL(forName name: String, kind: RemoteTitleKind) async -> URL? {
        await loadCacheIfNeeded()
        let key = cacheKey(name: name, kind: kind)
        if let custom = overrides[key] {
            return URL(string: custom)
        }
        return await automaticPosterURL(forName: name, kind: kind)
    }

    private enum Lookup {
        case found(URL)
        case notFound
        /// Rete, chiave sbagliata, risposta illeggibile: non va in cache,
        /// così si riprova alla prossima occasione.
        case failed
    }

    /// Copertina automatica (Wikipedia → iTunes) ignorando quelle
    /// dell'utente: serve anche al provider quando la copertina
    /// personalizzata viene rimossa.
    func automaticPosterURL(forName name: String, kind: RemoteTitleKind) async -> URL? {
        await loadCacheIfNeeded()
        let key = "v6|" + cacheKey(name: name, kind: kind)
        if let cached = cache[key] {
            return cached.isEmpty ? nil : URL(string: cached)
        }

        var anyFailed = false
        var wikiPoster: URL?
        // Titolo con cui chiedere a IMDb: quello inglese riconosciuto da
        // Wikipedia, altrimenti il nome così com'è (spesso è già inglese).
        var imdbTitle = Self.strippingYear(name)
        var imdbYear = Self.year(in: name)
        switch await wikiIdentify(name: name, kind: kind) {
        case .match(let match):
            wikiPoster = match.poster
            imdbTitle = Self.strippingDisambiguation(match.enTitle)
            imdbYear = imdbYear ?? Self.firstYear(in: match.enTitle)
        case .notFound: break
        case .failed: anyFailed = true
        }
        switch await fetchIMDb(title: imdbTitle, year: imdbYear, kind: kind) {
        case .found(let url): return store(url, key: key)
        case .notFound: break
        case .failed: anyFailed = true
        }
        if let wikiPoster { return store(wikiPoster, key: key) }
        switch await fetchITunes(name: name, kind: kind) {
        case .found(let url): return store(url, key: key)
        case .notFound: if !anyFailed { _ = store(nil, key: key) }
        case .failed: break
        }
        return nil
    }

    private func store(_ url: URL?, key: String) -> URL? {
        cache[key] = url?.absoluteString ?? ""
        saveCache()
        return url
    }

    /// Sostituisce per intero le copertine dell'utente (una per titolo
    /// presente sul server), chiamato a ogni costruzione del catalogo.
    func replaceOverrides(_ entries: [(name: String, kind: RemoteTitleKind, url: URL)]) async {
        await loadCacheIfNeeded()
        overrides = Dictionary(
            entries.map { (cacheKey(name: $0.name, kind: $0.kind), $0.url.absoluteString) },
            uniquingKeysWith: { first, _ in first }
        )
        saveOverrides()
    }

    /// Aggiorna la copertina dell'utente di un solo titolo (`nil` = rimossa).
    func setOverride(_ url: URL?, name: String, kind: RemoteTitleKind) async {
        await loadCacheIfNeeded()
        overrides[cacheKey(name: name, kind: kind)] = url?.absoluteString
        saveOverrides()
    }

    // MARK: - Wikipedia

    private struct WikiResponse: Decodable {
        var query: Query?
        struct Query: Decodable {
            var pages: [String: Page]?
        }
        struct Page: Decodable {
            var title: String
            var index: Int?
            var thumbnail: Thumbnail?
            var langlinks: [LangLink]?
        }
        struct Thumbnail: Decodable {
            var source: String
            var width: Int
            var height: Int
        }
        struct LangLink: Decodable {
            var title: String
            enum CodingKeys: String, CodingKey { case title = "*" }
        }
    }

    private struct WikiMatch {
        /// Titolo della voce inglese, con disambigua ("Moana (2026 film)").
        var enTitle: String
        /// Locandina della voce, se è verticale come una locandina.
        var poster: URL?
    }

    private enum WikiResult {
        case match(WikiMatch)
        case notFound
        case failed
    }

    /// Nessuna chiave richiesta. Cerca prima su it.wiki (titoli italiani:
    /// "Oceania" → "Oceania (film 2026)") e passa alla voce inglese
    /// collegata, dove sta la locandina (it.wiki non ospita locandine, solo
    /// fotogrammi); poi direttamente su en.wiki. Una voce vale come
    /// riconoscimento solo se è chiaramente un film/serie (disambigua tipo
    /// "(film 2026)"/"(TV series)") o se ha un'immagine a forma di locandina:
    /// evita di prendere "Oceania" il continente per il film. Un'immagine
    /// vale come locandina solo se è verticale (≥ 1,3 volte più alta che
    /// larga): scarta fotogrammi, title card, mappe.
    private func wikiIdentify(name: String, kind: RemoteTitleKind) async -> WikiResult {
        let query = Self.strippingYear(name)
        let wanted = Self.normalized(query)
        guard !wanted.isEmpty else { return .notFound }
        let year = Self.year(in: name)
        var anyFailed = false

        // 1. it.wiki → voce inglese collegata.
        let itSuffix = kind == .movie ? "film" : "serie televisiva"
        switch await wikiSearch(lang: "it", query: "\(query) \(itSuffix)", extraProps: ["langlinks"]) {
        case .success(let pages):
            if let page = Self.bestWikiPage(pages, wanted: wanted, year: year),
               let enTitle = page.langlinks?.first?.title {
                switch await wikiPoster(enTitle: enTitle) {
                case .found(let url):
                    return .match(WikiMatch(enTitle: enTitle, poster: url))
                case .notFound:
                    if Self.isWorkTitle(page.title) || Self.isWorkTitle(enTitle) {
                        return .match(WikiMatch(enTitle: enTitle, poster: nil))
                    }
                case .failed:
                    anyFailed = true
                }
            }
        case .failure:
            anyFailed = true
        }

        // 2. en.wiki direttamente.
        let enSuffix = kind == .movie ? "film" : "TV series"
        switch await wikiSearch(lang: "en", query: "\(query) \(enSuffix)", extraProps: []) {
        case .success(let pages):
            let works = pages.filter { Self.isPosterShaped($0.thumbnail) || Self.isWorkTitle($0.title) }
            if let page = Self.bestWikiPage(works, wanted: wanted, year: year) {
                let poster = Self.isPosterShaped(page.thumbnail) ? page.thumbnail.flatMap { URL(string: $0.source) } : nil
                return .match(WikiMatch(enTitle: page.title, poster: poster))
            }
        case .failure:
            anyFailed = true
        }
        return anyFailed ? .failed : .notFound
    }

    /// "(film 2026)", "(2026 film)", "(serie televisiva)", "(TV series)",
    /// "(miniseries)"…: la voce parla di un film o di una serie.
    private static func isWorkTitle(_ title: String) -> Bool {
        title.range(of: #"\((?:[^)]*\b)?(film|serie|series|miniseries|miniserie|TV)\b[^)]*\)\s*$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func strippingDisambiguation(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    }

    /// Primo anno 19xx/20xx nel testo ("Moana (2026 film)" → "2026").
    private static func firstYear(in s: String) -> String? {
        s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).map { String(s[$0]) }
    }

    private struct WikiError: Error {}

    private func wikiSearch(lang: String, query: String, extraProps: [String]) async -> Result<[WikiResponse.Page], WikiError> {
        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrlimit", value: "5"),
            URLQueryItem(name: "prop", value: (["pageimages"] + extraProps).joined(separator: "|")),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "780"),
            // Le locandine sono immagini non libere: senza, pageimages le salta.
            URLQueryItem(name: "pilicense", value: "any"),
            URLQueryItem(name: "lllang", value: "en"),
        ]
        guard let data = await wikiGET(components?.url),
              let decoded = try? JSONDecoder().decode(WikiResponse.self, from: data)
        else { return .failure(WikiError()) }
        let pages = (decoded.query?.pages.map { Array($0.values) } ?? [])
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
        return .success(pages)
    }

    private func wikiPoster(enTitle: String) async -> Lookup {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: enTitle),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "780"),
            URLQueryItem(name: "pilicense", value: "any"),
        ]
        guard let data = await wikiGET(components?.url),
              let decoded = try? JSONDecoder().decode(WikiResponse.self, from: data)
        else { return .failed }
        guard let thumb = decoded.query?.pages?.values.first?.thumbnail,
              Self.isPosterShaped(thumb), let url = URL(string: thumb.source)
        else { return .notFound }
        return .found(url)
    }

    // MARK: - IMDb

    private struct IMDbResponse: Decodable {
        var d: [Item]?
        struct Item: Decodable {
            /// Titolo (inglese).
            var l: String?
            var y: Int?
            /// Tipo: movie, tvMovie, tvSeries, tvMiniSeries, short, video…
            var qid: String?
            var i: Image?
        }
        struct Image: Decodable {
            var imageUrl: String
            var width: Int?
            var height: Int?
        }
    }

    /// Suggerimenti della barra di ricerca del sito IMDb: nessuna chiave né
    /// account, locandine in alta risoluzione. ⚠️ NON è un'API ufficiale
    /// (quella vera è a pagamento via AWS): può cambiare o sparire senza
    /// preavviso — in quel caso si ricade su Wikipedia/iTunes, niente si
    /// rompe. Vale solo un titolo identico (normalizzato) del tipo giusto;
    /// con un anno, quello (o ±1: uscite in anni diversi tra paesi),
    /// altrimenti il primo per rilevanza.
    private func fetchIMDb(title: String, year: String?, kind: RemoteTitleKind) async -> Lookup {
        let wanted = Self.normalized(title)
        guard !wanted.isEmpty else { return .notFound }
        let query = title.lowercased().replacingOccurrences(of: "/", with: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let first = query.first(where: { $0.isLetter || $0.isNumber }),
              let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/\(first.isASCII && first.isLetter ? String(first) : "x")/\(encoded).json")
        else { return .notFound }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(IMDbResponse.self, from: data)
        else { return .failed }

        let types: Set<String> = kind == .movie ? ["movie", "tvMovie"] : ["tvSeries", "tvMiniSeries"]
        let candidates = (decoded.d ?? []).filter { item in
            guard let image = item.i, let w = image.width, let h = image.height, w > 0 else { return false }
            return types.contains(item.qid ?? "")
                && Self.normalized(item.l ?? "") == wanted
                // 1,2 e non 1,3 come per Wikipedia: alcune locandine IMDb
                // sono 4:5 (House of the Dragon 3000×3750). Basta comunque
                // a scartare quadrati e immagini orizzontali.
                && Double(h) >= Double(w) * 1.2
        }
        let match: IMDbResponse.Item?
        if let year, let y = Int(year) {
            match = candidates.first { $0.y == y }
                ?? candidates.first { $0.y.map { abs($0 - y) == 1 } ?? false }
        } else {
            match = candidates.first
        }
        guard let imageURL = match?.i?.imageUrl else { return .notFound }
        // "…._V1_.jpg" è l'originale (anche 3000+ px): "_UX1000_" la fa
        // servire già ridimensionata a 1000 px di larghezza.
        let sized = imageURL.replacingOccurrences(of: "._V1_.jpg", with: "._V1_UX1000_.jpg")
        return URL(string: sized).map { .found($0) } ?? .notFound
    }

    /// Wikimedia chiede uno User-Agent che identifichi l'app.
    static let wikimediaUserAgent = "Curfs/2.2 (https://github.com/M-Tre-Consulting/Curfs)"

    private func wikiGET(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(Self.wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }

    private static func isPosterShaped(_ thumb: WikiResponse.Thumbnail?) -> Bool {
        guard let thumb, thumb.width > 0 else { return false }
        return Double(thumb.height) >= Double(thumb.width) * 1.3
    }

    /// Voce il cui titolo, tolta la disambigua tra parentesi ("Oceania (film
    /// 2026)", "Moana (2026 film)"), è esattamente quello cercato. Con un
    /// anno, preferisce la voce che lo riporta nella disambigua.
    private static func bestWikiPage(_ pages: [WikiResponse.Page], wanted: String, year: String?) -> WikiResponse.Page? {
        let matching = pages.filter { page in
            let base = page.title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            return normalized(base) == wanted
        }
        guard let year else { return matching.first }
        // Con un anno: la voce che lo riporta, oppure quella senza
        // disambigua (voce principale, es. "Inception"). Mai un'altra
        // versione datata ("Oceania (film 2016)" per "Oceania (2026)").
        return matching.first { $0.title.contains(year) }
            ?? matching.first { !$0.title.hasSuffix(")") }
    }

    // MARK: - iTunes

    private func fetchITunes(name: String, kind: RemoteTitleKind) async -> Lookup {
        let wantedName = Self.normalized(Self.strippingYear(name))
        guard !wantedName.isEmpty else { return .notFound }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: Self.strippingYear(name)),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return .failed }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return .failed }

        let wantedKinds: Set<String> = kind == .movie
            ? ["feature-movie"]
            : ["tv-episode", "tv-season"]
        // Niente eccezioni per i titoli tradotti ("Il Trono di Spade" →
        // "Game of Thrones" nel negozio USA): iTunes non permette di
        // distinguerli da un risultato qualunque (ordine e numero dei
        // risultati instabili), per quelli c'è la copertina manuale.
        guard let match = decoded.results.first(where: { item in
                  wantedKinds.contains(item.kind ?? "")
                      && Self.candidateNames(of: item, kind: kind).contains(wantedName)
              }),
              let artwork = match.artworkUrl100,
              let poster = URL(string: upsized(artwork))
        else { return .notFound }
        return .found(poster)
    }

    /// L'artwork di default è 100x100 (o più piccolo): sostituisce le
    /// dimensioni nel path con una risoluzione da locandina vera.
    private func upsized(_ artworkUrl100: String) -> String {
        for size in ["100x100bb", "60x60bb", "30x30bb"] where artworkUrl100.contains(size) {
            // Le serie hanno artwork quadrato: con 600x900 iTunes restituisce
            // comunque 600x600. 1000 per restare nitide su una card Retina.
            return artworkUrl100.replacingOccurrences(of: size, with: "1000x1500bb")
        }
        return artworkUrl100
    }

    /// Nomi con cui un risultato iTunes può corrispondere al titolo cercato,
    /// già normalizzati. Per le serie il nome dello show sta in `artistName`
    /// (episodi) o in `collectionName` prima di ", Season N" (stagioni).
    private static func candidateNames(of item: SearchResponse.Item, kind: RemoteTitleKind) -> Set<String> {
        var raw: [String?] = []
        switch kind {
        case .movie:
            raw = [item.trackName]
        case .series:
            let seasonless = item.collectionName?
                .replacingOccurrences(of: #",?\s*(Season|Stagione|Series)\s*\d+.*$"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            raw = [item.artistName, seasonless]
        }
        return Set(raw.compactMap { $0 }.map { normalized(strippingYear($0)) }.filter { !$0.isEmpty })
    }

    /// "Oceania (2026)" → "Oceania": l'anno tra parentesi nel nome non
    /// compare nei titoli di iTunes.
    private static func strippingYear(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[\(\[]\d{4}[\)\]]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Oceania (2026)" → "2026".
    private static func year(in s: String) -> String? {
        guard let range = s.range(of: #"[\(\[]\d{4}[\)\]]\s*$"#, options: .regularExpression) else { return nil }
        return String(s[range].filter(\.isNumber))
    }

    /// Solo lettere/cifre minuscole, senza accenti: "Il Trono di Spade" e
    /// "il-trono-di-spade" diventano uguali.
    private static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Chiave di un titolo, per le copertine dell'utente e (con prefisso
    /// `v6|`) per la cache delle automatiche. Le voci con prefissi più
    /// vecchi (prima del controllo sul titolo, spesso film a caso, o prima
    /// di Wikipedia) vengono ignorate e ricalcolate.
    private func cacheKey(name: String, kind: RemoteTitleKind) -> String {
        "\(kind.rawValue)|\(name.lowercased())"
    }

    // MARK: - Cache su disco

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "RemotePosters.json")
    }

    private static var overridesFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "RemotePosterOverrides.json")
    }

    private func loadCacheIfNeeded() async {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: Self.cacheFileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            // Le voci senza prefisso di versione sono della vecchia ricerca
            // senza controllo sul titolo: inutili, non le ricarichiamo.
            cache = decoded.filter { $0.key.hasPrefix("v6|") }
        }
        if let data = try? Data(contentsOf: Self.overridesFileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = decoded
        }
    }

    private func saveOverrides() {
        let snapshot = overrides
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.overridesFileURL, options: .atomic)
        }
    }

    private func saveCache() {
        let snapshot = cache
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.cacheFileURL, options: .atomic)
        }
    }
}
