//
//  ServerIntroIndex.swift
//  Curfs
//
//  Sigla e titoli di coda condivisi col server dei video.
//
//  Il server analizza da solo tutti gli episodi, di notte, con lo stesso
//  algoritmo dell'app (tv/server/curfs-intro.py) e scrive i risultati in
//  `.curfs/intro.json`: così il "salta intro" c'è anche in streaming e sulla
//  TV, che da soli non possono analizzare niente.
//
//  Al contrario, quando un dispositivo analizza un episodio scaricato (che è
//  lo stesso file del server: stessa dimensione) manda il risultato in
//  `.curfs/intro-devices/<hash>.json`: il server lo usa subito al posto della
//  sua analisi (la TV lo vede senza aspettare la notte) e risparmia il lavoro.
//
//  Sul dispositivo l'analisi locale vince sempre: il risultato del server si
//  usa solo finché quella non c'è o se non ha trovato niente.
//

import Foundation
import CryptoKit

@MainActor
final class ServerIntroIndex {
    static let shared = ServerIntroIndex()

    struct Ranges: Sendable {
        var intro: ClosedRange<Double>?
        var credits: ClosedRange<Double>?
        var isEmpty: Bool { intro == nil && credits == nil }
    }

    /// Quello che serve per mandare al server l'analisi di un file locale
    /// (MediaItem non si può passare tra attori).
    struct LocalResult: Sendable {
        let fileURL: URL
        let kind: String
        let title: String
        let show: String?
        let season: Int?
        let episode: Int?
        let intro: ClosedRange<Double>?
        let credits: ClosedRange<Double>?
    }

    private struct Entry: Decodable { let intro: [Double]?; let credits: [Double]? }
    private struct IndexFile: Decodable { let items: [String: Entry] }

    private var entries: [String: Entry]?
    private var loadedAt = Date.distantPast
    private var loading: Task<[String: Entry], Never>?
    private static let sharedKey = "Curfs.introShared"

    private init() {}

    // MARK: - Lettura

    /// Sigla/coda del file del server a questo percorso (non codificato).
    func ranges(forPath path: String) async -> Ranges? {
        let all = await index()
        guard let entry = all[path] else { return nil }
        let ranges = Ranges(intro: Self.range(entry.intro), credits: Self.range(entry.credits))
        return ranges.isEmpty ? nil : ranges
    }

    /// Per un item della libreria: in streaming dal suo URL, scaricato o
    /// importato cercandolo nel catalogo per nome.
    func ranges(for item: MediaItem) async -> Ranges? {
        guard item.kind == .episode, let base = RemoteSourceStore.current.baseURL else { return nil }
        var path = ProfileSync.serverPath(of: item, base: base)
        if path == nil {
            path = await ServerPathResolver(base: base).path(
                kind: item.kind.rawValue, title: item.title, show: item.showName,
                season: item.seasonNumber, episode: item.episodeNumber)
        }
        guard let path else { return nil }
        return await ranges(forPath: path)
    }

    private func index() async -> [String: Entry] {
        if let entries, Date.now.timeIntervalSince(loadedAt) < 300 { return entries }
        if let loading { return await loading.value }
        let task = Task<[String: Entry], Never> {
            guard let (session, base) = Self.session() else { return [:] }
            let url = base.appending(path: ".curfs").appending(path: "intro.json")
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let file = try? JSONDecoder().decode(IndexFile.self, from: data)
            else { return self.entries ?? [:] }
            return file.items
        }
        loading = task
        let result = await task.value
        loading = nil
        entries = result
        loadedAt = .now
        return result
    }

    // MARK: - Scrittura

    /// Manda al server il risultato dell'analisi di un file locale, se è lo
    /// stesso file che sta sul server (stessa dimensione: un episodio
    /// importato da un'altra fonte avrebbe tempi diversi). Una volta sola per
    /// file e risultato.
    func share(_ result: LocalResult) async {
        guard result.intro != nil || result.credits != nil,
              let base = RemoteSourceStore.current.baseURL,
              let localSize = (try? result.fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let path = await ServerPathResolver(base: base).path(
                kind: result.kind, title: result.title, show: result.show,
                season: result.season, episode: result.episode)
        else { return }

        let intro = result.intro.map { [Self.round($0.lowerBound), Self.round($0.upperBound)] }
        let credits = result.credits.map { [Self.round($0.lowerBound), Self.round($0.upperBound)] }
        var body: [String: Any] = ["v": 1, "path": path, "size": localSize, "at": Int(Date.now.timeIntervalSince1970)]
        if let intro { body["intro"] = intro }
        if let credits { body["credits"] = credits }
        let memo = "\(path)|\(localSize)|\(intro ?? [])|\(credits ?? [])"
        var done = UserDefaults.standard.stringArray(forKey: Self.sharedKey) ?? []
        guard !done.contains(memo) else { return }

        guard let (session, _) = Self.session() else { return }
        var fileURL = base
        for component in path.split(separator: "/") { fileURL.appendPathComponent(String(component)) }
        var head = URLRequest(url: fileURL)
        head.httpMethod = "HEAD"
        guard let (_, headResponse) = try? await session.data(for: head),
              let http = headResponse as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength == Int64(localSize)
        else { return }

        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        var put = URLRequest(url: base.appending(path: ".curfs").appending(path: "intro-devices").appending(path: "\(name).json"))
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let (_, putResponse) = try? await session.upload(for: put, from: data),
              let status = (putResponse as? HTTPURLResponse)?.statusCode, (200...299).contains(status)
        else { return }
        done.append(memo)
        UserDefaults.standard.set(Array(done.suffix(500)), forKey: Self.sharedKey)
    }

    // MARK: - Utilità

    private static func session() -> (URLSession, URL)? {
        let config = RemoteSourceStore.current
        guard let base = config.baseURL else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = config.authHeaders
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        return (URLSession(configuration: cfg), base)
    }

    private static func range(_ pair: [Double]?) -> ClosedRange<Double>? {
        guard let pair, pair.count == 2, pair[0] <= pair[1] else { return nil }
        return pair[0]...pair[1]
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
