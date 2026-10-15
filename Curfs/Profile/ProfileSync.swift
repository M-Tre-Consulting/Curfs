//
//  ProfileSync.swift
//  Curfs
//
//  Il profilo attivo su questo dispositivo (obbligatorio: senza, l'app mostra
//  solo "Chi guarda?", vedi RootTabView) e la sincronizzazione con il server
//  di due cose: la libreria (quali episodi e film ci sono) e il minutaggio.
//  I file scaricati restano del dispositivo: sugli altri lo stesso episodio
//  compare in streaming dal server.
//
//  Una sincronizzazione = leggi `library.json` e `progress.json`, applica
//  qui le voci più recenti (aggiunte → voci in streaming, rimozioni → via le
//  voci in streaming), rimanda su quelle in cui questo dispositivo è più
//  avanti. Unione per chiave, vince la voce più recente (`LibraryFile.merge`,
//  `ProgressFile.merge`). Parte all'apertura dell'app, al ritorno in primo
//  piano, quando la libreria cambia, ogni ~30 s mentre si guarda qualcosa e
//  alla chiusura del player.
//
//  Per aggiungere in streaming serve il percorso del file sul server: le voci
//  lo portano se il dispositivo d'origine lo conosceva (item in streaming),
//  altrimenti (episodi scaricati o importati) lo si cerca nel catalogo del
//  server per nome (`ServerPathResolver`).
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ProfileSync {
    static let shared = ProfileSync()

    private(set) var active: UserProfile?
    /// Ultimo elenco dei profili letto dal server.
    private(set) var profiles: [UserProfile] = []
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var syncQueued = false
    @ObservationIgnored private var lastPlaybackSync = Date.distantPast
    @ObservationIgnored private var libraryObserver: NSObjectProtocol?
    @ObservationIgnored private var lastItemCount = -1
    @ObservationIgnored private var librarySyncTask: Task<Void, Never>?

    private static let defaults = UserDefaults.standard
    private static let activeKey = "Curfs.profile.active"
    /// Episodi/film tolti dalla libreria e non ancora comunicati al server.
    private static let removedKey = "Curfs.profile.pendingRemovals"
    private static func libraryAppliedKey(_ id: String) -> String { "Curfs.profile.libraryAppliedAt.\(id)" }

    private init() {
        if let data = Self.defaults.data(forKey: Self.activeKey) {
            active = try? JSONDecoder().decode(UserProfile.self, from: data)
        }
    }

    var server: ProfileServer? { ProfileServer() }

    func avatarURL(for profile: UserProfile) -> URL? { server?.avatarURL(for: profile) }

    private func setActive(_ profile: UserProfile?) {
        active = profile
        if let profile, let data = try? JSONEncoder().encode(profile) {
            Self.defaults.set(data, forKey: Self.activeKey)
        } else {
            Self.defaults.removeObject(forKey: Self.activeKey)
        }
    }

    // MARK: - Profili

    func refreshProfiles() async throws {
        guard let server else { throw RemoteProviderError.notConfigured }
        let list = try await server.listProfiles()
        profiles = list
        // Nome/foto cambiati da un altro dispositivo.
        if let active, let fresh = list.first(where: { $0.id == active.id }), fresh != active {
            setActive(fresh)
        }
    }

    /// Crea il profilo sul server e lo rende attivo. Libreria e minutaggio
    /// già presenti su questo dispositivo diventano suoi.
    func create(name: String, avatarJPEG: Data?) async throws {
        guard let server else { throw RemoteProviderError.notConfigured }
        let now = Date.now.millisecondsSince1970
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        var profile = UserProfile(id: String(id), name: name, avatar: nil, created: now)
        if let avatarJPEG {
            try await server.uploadAvatar(avatarJPEG, for: profile.id)
            profile.avatar = Int(now / 1000)
        }
        try await server.save(profile)
        try await server.saveProgress(ProgressFile(), for: profile.id)
        try await switchTo(profile)
        profiles.append(profile)
    }

    /// `avatarJPEG`: nuova foto; `removeAvatar`: togli quella che c'è.
    func update(_ profile: UserProfile, name: String, avatarJPEG: Data?, removeAvatar: Bool) async throws {
        guard let server else { throw RemoteProviderError.notConfigured }
        var updated = profile
        updated.name = name
        if let avatarJPEG {
            try await server.uploadAvatar(avatarJPEG, for: profile.id)
            updated.avatar = Int(Date.now.timeIntervalSince1970)
        } else if removeAvatar, profile.avatar != nil {
            try await server.deleteAvatar(for: profile.id)
            updated.avatar = nil
        }
        try await server.save(updated)
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = updated }
        if active?.id == profile.id { setActive(updated) }
    }

    func delete(_ profile: UserProfile) async throws {
        guard let server else { throw RemoteProviderError.notConfigured }
        try await server.deleteProfile(id: profile.id)
        profiles.removeAll { $0.id == profile.id }
        Self.defaults.removeObject(forKey: Self.libraryAppliedKey(profile.id))
        if active?.id == profile.id { setActive(nil) }
    }

    /// Entra in un profilo. Da nessun profilo: libreria e minutaggio del
    /// dispositivo si uniscono a quelli del profilo. Da un altro profilo:
    /// prima si salva quello vecchio sul server, poi il dispositivo riparte da
    /// libreria e minutaggio del nuovo (quelli del vecchio restano sul server).
    /// I file scaricati restano: entrano nella libreria del nuovo profilo.
    func switchTo(_ profile: UserProfile) async throws {
        guard profile.id != active?.id else { return }
        await waitForPending()
        if let previous = active {
            // Se il vecchio profilo non si riesce a salvare, meglio non
            // cambiare: si perderebbe quello non ancora inviato.
            try await performSync(for: previous)
            resetLocalState()
        }
        Self.defaults.removeObject(forKey: Self.libraryAppliedKey(profile.id))
        setActive(profile)
        try await performSync(for: profile)
    }

    // MARK: - Cambiamenti della libreria

    /// Un episodio/film tolto dalla libreria (vedi LibraryMaintenance): la
    /// rimozione va anche sugli altri dispositivi.
    func noteRemoved(_ item: MediaItem) {
        guard active != nil, let key = SyncKey.key(for: item) else { return }
        var pending = Self.defaults.dictionary(forKey: Self.removedKey) as? [String: Double] ?? [:]
        pending[key] = Double(Date.now.millisecondsSince1970)
        Self.defaults.set(pending, forKey: Self.removedKey)
    }

    /// Sincronizza quando cambia il numero di voci in libreria (aggiunte da
    /// Cerca, download finiti, rimozioni). I salvataggi del minutaggio durante
    /// la riproduzione non cambiano il conteggio e non fanno partire nulla.
    func observeLibraryChanges() {
        guard libraryObserver == nil else { return }
        libraryObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in ProfileSync.shared.libraryMaybeChanged() }
        }
    }

    private func libraryMaybeChanged() {
        let count = (try? AppModelContainer.shared.mainContext.fetchCount(FetchDescriptor<MediaItem>())) ?? -1
        guard count != lastItemCount else { return }
        let first = lastItemCount < 0
        lastItemCount = count
        guard !first, active != nil else { return }
        librarySyncTask?.cancel()
        librarySyncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.sync()
        }
    }

    // MARK: - Sincronizzazione

    /// Sincronizza adesso (in coda a quella eventualmente in corso).
    func sync() {
        guard active != nil, !syncQueued else { return }
        syncQueued = true
        let previous = chain
        chain = Task {
            await previous?.value
            self.syncQueued = false
            guard let profile = self.active else { return }
            try? await self.performSync(for: profile)
        }
    }

    /// Chiamata dal player a ogni salvataggio dell'avanzamento: durante la
    /// riproduzione al massimo ogni 30 s, subito se `force` (pausa, chiusura).
    func playbackProgressChanged(force: Bool) {
        guard active != nil else { return }
        guard force || Date.now.timeIntervalSince(lastPlaybackSync) > 30 else { return }
        lastPlaybackSync = .now
        sync()
    }

    private func waitForPending() async {
        await chain?.value
    }

    private func performSync(for profile: UserProfile) async throws {
        guard let server else { throw RemoteProviderError.notConfigured }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let context = AppModelContainer.shared.mainContext
            let resolver = ServerPathResolver(base: server.baseURL)

            var library = try await server.library(for: profile.id)
            let libraryNewer = await applyLibrary(library, profileID: profile.id, context: context, resolver: resolver)
            if !libraryNewer.isEmpty {
                library.merge(libraryNewer)
                try await server.saveLibrary(library, for: profile.id)
            }
            Self.defaults.removeObject(forKey: Self.removedKey)

            var progress = try await server.progress(for: profile.id)
            let progressNewer = applyProgress(progress, profileID: profile.id, context: context, resolver: resolver)
            if !progressNewer.isEmpty {
                progress.merge(progressNewer)
                try await server.saveProgress(progress, for: profile.id)
            }
            lastItemCount = (try? context.fetchCount(FetchDescriptor<MediaItem>())) ?? lastItemCount
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func allItems(_ context: ModelContext) -> [MediaItem] {
        (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
    }

    private func itemsByKey(_ items: [MediaItem]) -> [String: [MediaItem]] {
        var byKey: [String: [MediaItem]] = [:]
        for item in items {
            guard let key = SyncKey.key(for: item) else { continue }
            byKey[key, default: []].append(item)
        }
        return byKey
    }

    // MARK: Libreria

    /// Applica la libreria del server e restituisce le voci in cui questo
    /// dispositivo è più avanti (aggiunte e rimozioni da mandare su).
    private func applyLibrary(_ remote: LibraryFile, profileID: String, context: ModelContext, resolver: ServerPathResolver) async -> [String: LibraryEntry] {
        let appliedKey = Self.libraryAppliedKey(profileID)
        let appliedAt = Int64(Self.defaults.double(forKey: appliedKey))
        let pendingRemovals = (Self.defaults.dictionary(forKey: Self.removedKey) as? [String: Double] ?? [:])
            .mapValues { Int64($0) }
        var items = allItems(context)
        var byKey = itemsByKey(items)
        var newestApplied = appliedAt
        var changed = false

        for (key, entry) in remote.items {
            newestApplied = max(newestApplied, entry.at)
            let local = byKey[key] ?? []
            if entry.isRemoved {
                // Tolto altrove: via le voci in streaming aggiunte prima. I file
                // scaricati restano, sono di questo dispositivo.
                for item in local where item.isRemote && item.dateAdded.millisecondsSince1970 <= entry.at {
                    context.delete(item)
                    changed = true
                }
                continue
            }
            guard local.isEmpty, entry.at > appliedAt, pendingRemovals[key] == nil else { continue }
            let path: String?
            if let known = entry.path {
                path = known
            } else {
                path = await resolver.path(kind: entry.kind, title: entry.title, show: entry.show, season: entry.season, episode: entry.episode)
            }
            guard let path, let item = streamingItem(kind: entry.kind, title: entry.title, show: entry.show,
                                                     season: entry.season, episode: entry.episode, path: path, items: items) else { continue }
            item.dateAdded = Date(millisecondsSince1970: entry.at)
            context.insert(item)
            items.append(item)
            byKey[key] = [item]
            changed = true
        }
        if changed { try? context.save() }
        Self.defaults.set(Double(newestApplied), forKey: appliedKey)

        items = allItems(context)
        byKey = itemsByKey(items)
        var newer: [String: LibraryEntry] = [:]
        for (key, group) in byKey {
            guard let first = group.min(by: { $0.dateAdded < $1.dateAdded }) else { continue }
            let added = first.dateAdded.millisecondsSince1970
            if let existing = remote.items[key] {
                // Già presente sul server, o tolto dopo che qui è stato aggiunto
                // (qui resta solo perché scaricato): niente da mandare.
                if !existing.isRemoved || existing.at >= added { continue }
            }
            var path = group.lazy.compactMap { Self.serverPath(of: $0, base: resolver.base) }.first
            if path == nil {
                path = await resolver.path(kind: first.kind.rawValue, title: first.title, show: first.showName,
                                           season: first.seasonNumber, episode: first.episodeNumber)
            }
            newer[key] = LibraryEntry(at: added, removed: nil, kind: first.kind.rawValue, title: first.title,
                                      show: first.showName, season: first.seasonNumber, episode: first.episodeNumber, path: path)
        }
        for (key, at) in pendingRemovals where byKey[key] == nil {
            guard let existing = remote.items[key], !existing.isRemoved, existing.at < at else { continue }
            var removal = existing
            removal.at = at
            removal.removed = true
            newer[key] = removal
        }
        return newer
    }

    // MARK: Minutaggio

    /// Applica il minutaggio del server alla libreria e restituisce le voci
    /// in cui la libreria è più avanti (da mandare al server).
    private func applyProgress(_ remote: ProgressFile, profileID: String, context: ModelContext, resolver: ServerPathResolver) -> [String: ProgressEntry] {
        // Qui si aggiornano solo le voci già in libreria: cosa c'è in libreria
        // lo decide library.json (un episodio guardato altrove ci entra da lì).
        let byKey = itemsByKey(allItems(context))
        var changed = false

        for (key, entry) in remote.entries {
            guard let local = byKey[key] else { continue }
            for item in local where (item.lastPlayedAt?.millisecondsSince1970 ?? 0) < entry.at {
                item.playbackPosition = entry.pos
                item.isFinished = entry.done
                item.lastPlayedAt = Date(millisecondsSince1970: entry.at)
                if item.duration <= 0, entry.dur > 0 { item.duration = entry.dur }
                changed = true
            }
        }
        if changed { try? context.save() }

        var newer: [String: ProgressEntry] = [:]
        for (key, group) in byKey {
            guard let latest = group.filter({ $0.lastPlayedAt != nil }).max(by: { $0.lastPlayedAt! < $1.lastPlayedAt! }),
                  let at = latest.lastPlayedAt?.millisecondsSince1970 else { continue }
            let existing = remote.entries[key]
            if let existing, existing.at >= at { continue }
            // Aperto e chiuso subito, mai guardato: non è un'informazione.
            if existing == nil, latest.playbackPosition < 5, !latest.isFinished { continue }
            newer[key] = ProgressEntry(
                pos: latest.playbackPosition,
                dur: latest.duration,
                done: latest.isFinished,
                at: at,
                kind: latest.kind.rawValue,
                title: latest.title,
                show: latest.showName,
                season: latest.seasonNumber,
                episode: latest.episodeNumber,
                path: group.lazy.compactMap { Self.serverPath(of: $0, base: resolver.base) }.first
            )
        }
        return newer
    }

    // MARK: Utilità

    /// Voce in streaming per un episodio/film che sta sul server. Per una
    /// serie già in libreria usa il nome che ha qui ("Game Of Thrones" e
    /// "Game of Thrones" devono finire nella stessa serie).
    private func streamingItem(kind rawKind: String, title: String, show: String?, season: Int?, episode: Int?,
                               path: String, items: [MediaItem]) -> MediaItem? {
        guard let base = server?.baseURL else { return nil }
        var url = base
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        let kind = MediaKind(rawValue: rawKind) ?? .movie
        if kind == .episode {
            guard let show, let season, let episode else { return nil }
            let normalized = SyncKey.normalized(show)
            let localName = items.lazy.compactMap(\.showName).first { SyncKey.normalized($0) == normalized } ?? show
            return MediaItem(title: title, kind: .episode, showName: localName, seasonNumber: season, episodeNumber: episode,
                             relativePath: "", remoteURLString: url.absoluteString, remoteOrigin: true)
        }
        return MediaItem(title: title, kind: .movie, relativePath: "", remoteURLString: url.absoluteString, remoteOrigin: true)
    }

    /// Percorso sul server (non codificato) di un item in streaming.
    static func serverPath(of item: MediaItem, base: URL?) -> String? {
        guard let remote = item.remoteURLString, let base else { return nil }
        let prefix = base.absoluteString + "/"
        guard remote.hasPrefix(prefix) else { return nil }
        return String(remote.dropFirst(prefix.count)).removingPercentEncoding
    }

    /// Cambio di profilo: libreria in streaming e minutaggio erano del
    /// profilo di prima. I file scaricati restano.
    private func resetLocalState() {
        let context = AppModelContainer.shared.mainContext
        for item in allItems(context) {
            if item.isRemote {
                context.delete(item)
            } else if item.lastPlayedAt != nil || item.playbackPosition > 0 || item.isFinished {
                item.playbackPosition = 0
                item.isFinished = false
                item.lastPlayedAt = nil
            }
        }
        try? context.save()
        Self.defaults.removeObject(forKey: Self.removedKey)
    }
}

/// Trova sul server il file di un episodio/film per nome, dal catalogo di
/// Cerca: serve per gli episodi scaricati o importati, che non ricordano da
/// dove vengono. Il catalogo si carica solo se serve, una volta per
/// sincronizzazione; se il server non risponde, nessun percorso.
@MainActor
final class ServerPathResolver {
    let base: URL
    private var titles: [RemoteTitle]?
    private var seasons: [String: [RemoteSeason]] = [:]

    init(base: URL) { self.base = base }

    func path(kind: String, title: String, show: String?, season: Int?, episode: Int?) async -> String? {
        let provider = RemoteContentProviderRegistry.shared
        if titles == nil { titles = (try? await provider.search(query: "")) ?? [] }
        guard let titles, !titles.isEmpty else { return nil }

        let target: (RemoteTitle, RemoteEpisode?)
        if kind == MediaKind.episode.rawValue {
            guard let show, let season, let episode else { return nil }
            let series = titles.filter { $0.kind == .series }
            let wanted = SyncKey.normalized(show)
            let match = series.first { SyncKey.normalized($0.name) == wanted }
                ?? ShowNameMatcher.bestMatch(for: show, in: series.map(\.name)).flatMap { name in series.first { $0.name == name } }
            guard let match else { return nil }
            if seasons[match.id] == nil { seasons[match.id] = (try? await provider.seasons(for: match)) ?? [] }
            guard let ep = seasons[match.id]?.first(where: { $0.number == season })?.episodes.first(where: { $0.number == episode })
            else { return nil }
            target = (match, ep)
        } else {
            let wanted = SyncKey.movie(title: title)
            guard let match = titles.first(where: { $0.kind == .movie && SyncKey.movie(title: $0.name) == wanted }) else { return nil }
            target = (match, nil)
        }
        guard let stream = try? await provider.streamTarget(for: target.0, episode: target.1) else { return nil }
        let prefix = base.absoluteString + "/"
        let absolute = stream.url.absoluteString
        guard absolute.hasPrefix(prefix) else { return nil }
        return String(absolute.dropFirst(prefix.count)).removingPercentEncoding
    }
}
