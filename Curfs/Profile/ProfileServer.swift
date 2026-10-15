//
//  ProfileServer.swift
//  Curfs
//
//  Lettura/scrittura dei profili sul server (vedi ProfileModels per la
//  struttura delle cartelle). Stesso server e stesse credenziali di Cerca:
//  GET con gli elenchi JSON di nginx, PUT/DELETE con il suo WebDAV, abilitato
//  per la sola cartella `.curfs/` (vedi `tv/server/README` dei profili).
//

import Foundation

struct ProfileServer: Sendable {
    let baseURL: URL
    private let session: URLSession

    init?(config: RemoteSourceConfig = RemoteSourceStore.current) {
        guard let baseURL = config.baseURL else { return nil }
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = config.authHeaders
        // Il minutaggio cambia di continuo: mai una risposta dalla cache.
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    private var profilesRoot: URL {
        baseURL.appending(path: ".curfs").appending(path: "profiles")
    }

    private func folder(_ id: String) -> URL { profilesRoot.appending(path: id) }

    func avatarURL(for profile: UserProfile) -> URL? {
        guard let version = profile.avatar else { return nil }
        var components = URLComponents(url: folder(profile.id).appending(path: "avatar.jpg"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "v", value: String(version))]
        return components?.url
    }

    // MARK: - Profili

    func listProfiles() async throws -> [UserProfile] {
        struct DirEntry: Decodable { let name: String; let type: String }
        let listURL = URL(string: profilesRoot.absoluteString + "/") ?? profilesRoot
        var request = URLRequest(url: listURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        // Nessun profilo ancora creato: la cartella non esiste.
        if response.statusCode == 404 { return [] }
        try Self.check(response)
        guard let entries = try? JSONDecoder().decode([DirEntry].self, from: data) else {
            throw RemoteProviderError.badListing
        }
        let ids = entries.filter { $0.type == "directory" }.map(\.name)
        let profiles = await withTaskGroup(of: UserProfile?.self) { group in
            for id in ids {
                group.addTask { try? await self.profile(id: id) }
            }
            var result: [UserProfile] = []
            for await profile in group { if let profile { result.append(profile) } }
            return result
        }
        return profiles.sorted { ($0.created ?? 0, $0.name) < ($1.created ?? 0, $1.name) }
    }

    func profile(id: String) async throws -> UserProfile? {
        let (data, response) = try await send(URLRequest(url: folder(id).appending(path: "profile.json")))
        if response.statusCode == 404 { return nil }
        try Self.check(response)
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    func save(_ profile: UserProfile) async throws {
        let data = try JSONEncoder().encode(profile)
        try await put(data, to: folder(profile.id).appending(path: "profile.json"), type: "application/json")
    }

    func uploadAvatar(_ jpeg: Data, for id: String) async throws {
        try await put(jpeg, to: folder(id).appending(path: "avatar.jpg"), type: "image/jpeg")
    }

    func deleteAvatar(for id: String) async throws {
        try await delete(folder(id).appending(path: "avatar.jpg"))
    }

    /// Cancella il profilo con tutto il suo minutaggio (cartella intera).
    func deleteProfile(id: String) async throws {
        try await delete(URL(string: folder(id).absoluteString + "/") ?? folder(id))
    }

    // MARK: - Minutaggio

    func progress(for id: String) async throws -> ProgressFile {
        let (data, response) = try await send(URLRequest(url: folder(id).appending(path: "progress.json")))
        if response.statusCode == 404 { return ProgressFile() }
        try Self.check(response)
        // Un file rovinato non deve bloccare la sincronizzazione: si riparte.
        return (try? JSONDecoder().decode(ProgressFile.self, from: data)) ?? ProgressFile()
    }

    func saveProgress(_ file: ProgressFile, for id: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await put(encoder.encode(file), to: folder(id).appending(path: "progress.json"), type: "application/json")
    }

    // MARK: - HTTP

    private func put(_ data: Data, to url: URL, type: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let response: HTTPURLResponse
        do {
            let (_, raw) = try await session.upload(for: request, from: data)
            guard let http = raw as? HTTPURLResponse else { throw RemoteProviderError.notConfigured }
            response = http
        } catch {
            throw RemoteProviderError.mapped(error, host: baseURL.host())
        }
        try Self.check(response)
    }

    private func delete(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await send(request)
        if response.statusCode == 404 { return }
        try Self.check(response)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteProviderError.notConfigured }
            return (data, http)
        } catch {
            throw RemoteProviderError.mapped(error, host: baseURL.host())
        }
    }

    private static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw RemoteProviderError.unauthorized
        // nginx senza `dav_methods` per `.curfs/`.
        case 405, 501: throw RemoteProviderError.profilesNotSupported
        default: throw RemoteProviderError.server(status: response.statusCode)
        }
    }
}
