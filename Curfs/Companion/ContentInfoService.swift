//
//  ContentInfoService.swift
//  Curfs
//
//  Cosa sa Curfs AI del titolo che si sta guardando, preso da fonti aperte e
//  gratuite (niente chiavi né account):
//  - serie: TVmaze (api.tvmaze.com, dati CC BY-SA), che trova la serie anche
//    col titolo italiano ("Il Trono di Spade" → Game of Thrones) e dà cast e
//    trama breve di ogni episodio; per gli ultimi episodi visti la trama vera
//    dalla loro voce di Wikipedia;
//  - film: la voce di Wikipedia (testo CC BY-SA), trama e cast; si cerca
//    sulla Wikipedia della lingua dell'app e si passa a quella inglese, dove la
//    sezione "Plot" c'è quasi sempre.
//  Il testo serve solo da contesto al modello sul dispositivo: Curfs manda a
//  questi servizi il titolo, nient'altro. Risultati in memoria per la vita
//  dell'app (anche i "non trovato", per non richiedere a ogni apertura).
//

import Foundation

nonisolated struct ShowInfo: Sendable {
    struct Episode: Sendable {
        let season: Int
        let number: Int
        let name: String
        let summary: String
        let url: URL?
    }
    let name: String
    let url: URL?
    let summary: String
    /// "Attore as Personaggio".
    let cast: [String]
    let episodes: [Episode]

    func episode(season: Int?, number: Int?) -> Episode? {
        guard let season, let number else { return nil }
        return episodes.first { $0.season == season && $0.number == number }
    }

    /// Gli episodi che vengono prima di quello indicato, in ordine.
    func episodes(before season: Int, _ number: Int) -> [Episode] {
        episodes.filter { ($0.season, $0.number) < (season, number) }
    }
}

nonisolated struct MovieInfo: Sendable {
    let title: String
    let url: URL?
    /// La trama intera, in paragrafi (si taglia a seconda di dove si è arrivati).
    let plot: [String]
    let cast: String
}

actor ContentInfoService {
    static let shared = ContentInfoService()

    private var shows: [String: ShowInfo?] = [:]
    private var movies: [String: MovieInfo?] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    // MARK: - Serie (TVmaze)

    func show(named name: String) async -> ShowInfo? {
        let key = Self.normalized(name)
        if let cached = shows[key] { return cached }
        let info = await fetchShow(name)
        // Un errore di rete non si ricorda: la volta dopo si riprova.
        if info.failed { return nil }
        shows[key] = info.value
        return info.value
    }

    private struct TVMazeShow: Decodable {
        struct Embedded: Decodable {
            var cast: [CastEntry]?
            var episodes: [TVMazeEpisode]?
        }
        struct CastEntry: Decodable {
            struct Named: Decodable { var name: String }
            var person: Named
            var character: Named
        }
        var name: String
        var url: String?
        var summary: String?
        var _embedded: Embedded?
    }

    private struct TVMazeEpisode: Decodable {
        var season: Int?
        var number: Int?
        var name: String?
        var summary: String?
        var url: String?
    }

    private func fetchShow(_ name: String) async -> (value: ShowInfo?, failed: Bool) {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")!
        components.queryItems = [
            URLQueryItem(name: "q", value: Self.strippingYear(name)),
            URLQueryItem(name: "embed[]", value: "cast"),
            URLQueryItem(name: "embed[]", value: "episodes"),
        ]
        guard let url = components.url else { return (nil, false) }
        do {
            let (data, response) = try await Self.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return (nil, false) }
            guard status == 200 else { return (nil, true) }
            let show = try JSONDecoder().decode(TVMazeShow.self, from: data)
            let cast = (show._embedded?.cast ?? []).map { "\($0.person.name) as \($0.character.name)" }
            let episodes = (show._embedded?.episodes ?? []).compactMap { ep -> ShowInfo.Episode? in
                guard let season = ep.season, let number = ep.number else { return nil }
                return ShowInfo.Episode(
                    season: season, number: number, name: ep.name ?? "",
                    summary: Self.plainText(ep.summary ?? ""), url: ep.url.flatMap(URL.init(string:))
                )
            }
            return (ShowInfo(
                name: show.name, url: show.url.flatMap(URL.init(string:)),
                summary: Self.plainText(show.summary ?? ""), cast: cast, episodes: episodes
            ), false)
        } catch {
            return (nil, true)
        }
    }

    // MARK: - Film (Wikipedia)

    func movie(titled title: String) async -> MovieInfo? {
        let key = Self.normalized(title) + "|" + (Self.year(in: title) ?? "")
        if let cached = movies[key] { return cached }
        let info = await fetchMovie(title)
        if info.failed { return nil }
        movies[key] = info.value
        return info.value
    }

    private static let plotSections: Set<String> = ["plot", "synopsis", "plot summary", "trama", "argumento", "sinopsis", "résumé", "handlung", "inhalt"]
    private static let castSections: Set<String> = ["cast", "voice cast", "interpreti e personaggi", "doppiatori originali", "reparto", "distribution", "besetzung"]

    private func fetchMovie(_ title: String) async -> (value: MovieInfo?, failed: Bool) {
        let clean = Self.strippingYear(title)
        let year = Self.year(in: title)
        // Lingua dell'app, poi italiano (i nomi dei file spesso lo sono anche
        // con l'app in inglese: "Doctor Strange nel Multiverso della Follia"), poi inglese.
        var languages: [String] = []
        for lang in [CompanionLanguage.code, "it", "en"] where !languages.contains(lang) { languages.append(lang) }

        var failed = false
        for lang in languages {
            let query = [clean, year, "film"].compactMap { $0 }.joined(separator: " ")
            guard let hits = await wikiSearch(lang: lang, query: query) else { failed = true; continue }
            guard let page = Self.bestPage(hits, wanted: clean, year: year) else { continue }
            // Dalla Wikipedia locale si passa alla voce inglese, se c'è.
            var target = (lang: lang, title: page)
            if lang != "en", let english = await wikiEnglishTitle(lang: lang, title: page) {
                target = ("en", english)
            }
            if let info = await wikiMovie(lang: target.lang, title: target.title) { return (info, false) }
            if target.lang != lang, let info = await wikiMovie(lang: lang, title: page) { return (info, false) }
        }
        return (nil, failed)
    }

    private struct WikiSearch: Decodable {
        struct Query: Decodable { var search: [Hit] }
        struct Hit: Decodable { var title: String }
        var query: Query?
    }

    private func wikiSearch(lang: String, query: String) async -> [String]? {
        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query), .init(name: "srlimit", value: "6"),
            .init(name: "format", value: "json"),
        ]
        guard let data = await wikiGET(components.url),
              let result = try? JSONDecoder().decode(WikiSearch.self, from: data) else { return nil }
        return result.query?.search.map(\.title) ?? []
    }

    private struct WikiPages: Decodable {
        struct Query: Decodable { var pages: [Page] }
        struct Page: Decodable {
            struct LangLink: Decodable { var title: String }
            var title: String
            var fullurl: String?
            var extract: String?
            var langlinks: [LangLink]?
            var missing: Bool?
        }
        var query: Query?
    }

    private func wikiEnglishTitle(lang: String, title: String) async -> String? {
        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "prop", value: "langlinks"),
            .init(name: "lllang", value: "en"), .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
        ]
        guard let data = await wikiGET(components.url),
              let result = try? JSONDecoder().decode(WikiPages.self, from: data) else { return nil }
        return result.query?.pages.first?.langlinks?.first?.title
    }

    private func wikiMovie(lang: String, title: String) async -> MovieInfo? {
        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "prop", value: "extracts|info"),
            .init(name: "inprop", value: "url"), .init(name: "explaintext", value: "1"),
            .init(name: "exsectionformat", value: "wiki"), .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
        ]
        guard let data = await wikiGET(components.url),
              let page = (try? JSONDecoder().decode(WikiPages.self, from: data))?.query?.pages.first,
              page.missing != true, let extract = page.extract else { return nil }
        let sections = Self.sections(of: extract)
        guard let plot = sections.first(where: { Self.plotSections.contains($0.heading) })?.body,
              !plot.isEmpty else { return nil }
        let cast = sections.first(where: { Self.castSections.contains($0.heading) })?.body ?? ""
        let paragraphs = plot.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return MovieInfo(
            title: page.title, url: page.fullurl.flatMap(URL.init(string:)),
            plot: paragraphs, cast: String(cast.prefix(900))
        )
    }

    /// Le sezioni di primo e secondo livello del testo semplice di una voce
    /// ("== Plot ==" …). Il corpo di una sezione arriva fino alla prossima
    /// dello stesso livello o superiore.
    private static func sections(of text: String) -> [(heading: String, body: String)] {
        var result: [(String, String)] = []
        var heading: String?
        var body: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=="), trimmed.hasSuffix("=="), !trimmed.hasPrefix("===") {
                if let heading { result.append((heading, body.joined(separator: "\n"))) }
                heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "= ")).lowercased()
                body = []
            } else if trimmed.hasPrefix("===") {
                continue
            } else {
                body.append(line)
            }
        }
        if let heading { result.append((heading, body.joined(separator: "\n"))) }
        return result.map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Una voce che si chiama come il film; con l'anno nel nome vale quella
    /// che lo riporta ("Oceania (film 2016)") o quella senza disambigua.
    private static func bestPage(_ titles: [String], wanted: String, year: String?) -> String? {
        let target = normalized(wanted)
        let matching = titles.filter { normalized(strippingDisambiguation($0)) == target }
        if let year, let dated = matching.first(where: { $0.contains(year) }) { return dated }
        if let filmPage = matching.first(where: { $0.lowercased().contains("film") }) { return filmPage }
        return matching.first
    }

    // MARK: - Episodi (Wikipedia)

    /// La trama vera di un episodio dalla sua voce su Wikipedia inglese
    /// ("Cherokee Rose (The Walking Dead)", sezione Plot): quella di TVmaze è
    /// un teaser di due righe ("Shane makes a deadly sacrifice") e il modello
    /// ci ricamava sopra fatti inventati. Solo per episodi già visti.
    func episodePlot(show: String, name: String) async -> (plot: String, url: URL?)? {
        let key = Self.normalized(show) + "|" + Self.normalized(name)
        if let cached = episodePlots[key] { return cached }
        guard !name.isEmpty, let hits = await wikiSearch(lang: "en", query: "\(name) \(show) episode") else { return nil }
        let target = Self.normalized(name), showKey = Self.normalized(show)
        // Il titolo della voce è il nome dell'episodio, con o senza la serie
        // tra parentesi ("Winter Is Coming", "Dragonstone (Game of Thrones episode)").
        let page = hits.first { hit in
            guard Self.normalized(Self.strippingDisambiguation(hit)) == target else { return false }
            let note = hit.range(of: #"\(([^)]*)\)\s*$"#, options: .regularExpression).map { Self.normalized(String(hit[$0])) }
            return note == nil || note!.contains(showKey) || note!.contains("episode")
        }
        var result: (String, URL?)?
        if let page, let info = await wikiPlot(lang: "en", title: page) { result = info }
        episodePlots[key] = result
        return result
    }

    private var episodePlots: [String: (plot: String, url: URL?)?] = [:]

    private func wikiPlot(lang: String, title: String) async -> (String, URL?)? {
        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "prop", value: "extracts|info"),
            .init(name: "inprop", value: "url"), .init(name: "explaintext", value: "1"),
            .init(name: "exsectionformat", value: "wiki"), .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
        ]
        guard let data = await wikiGET(components.url),
              let page = (try? JSONDecoder().decode(WikiPages.self, from: data))?.query?.pages.first,
              page.missing != true, let extract = page.extract,
              let plot = Self.sections(of: extract).first(where: { Self.plotSections.contains($0.heading) })?.body,
              !plot.isEmpty
        else { return nil }
        return (plot.replacingOccurrences(of: "\n\n", with: "\n"), page.fullurl.flatMap(URL.init(string:)))
    }

    private func wikiGET(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        // Wikimedia chiede uno User-Agent che identifichi l'app.
        request.setValue("Curfs/1.0 (https://mtre-consulting.it; info@mtre-consulting.it)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Testo

    /// I riassunti di TVmaze sono in HTML ("<p>…</p>").
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func strippingYear(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\((19|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func year(in s: String) -> String? {
        guard let range = s.range(of: #"\((19|20)\d{2}\)\s*$"#, options: .regularExpression) else { return nil }
        return String(s[range].filter(\.isNumber))
    }

    private static func strippingDisambiguation(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    }
}

/// La lingua in cui l'app è mostrata (una delle 5 tradotte, sennò inglese):
/// Curfs AI risponde in questa.
nonisolated enum CompanionLanguage {
    static var code: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return String(preferred.prefix(2))
    }

    /// Nome in inglese ("Italian"), per le istruzioni del modello.
    static var englishName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
