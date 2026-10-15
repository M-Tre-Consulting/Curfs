//
//  ProfileSync.swift
//  Curfs
//
//  Il profilo attivo su questo dispositivo (obbligatorio: senza, l'app mostra
//  solo "Chi guarda?", vedi RootTabView) e la sincronizzazione del
//  minutaggio con il server. La libreria resta del dispositivo (i download
//  sono qui): si sincronizza solo a che punto sei di ogni episodio/film.
//
//  Una sincronizzazione = leggi `progress.json` dal server, applica alla
//  libreria le voci più recenti di quelle locali, rimanda su quelle locali
//  più recenti (unione per chiave, vince il più recente: vedi
//  `ProgressFile.merge`). Parte all'apertura dell'app, al ritorno in primo
//  piano, ogni ~30 s mentre si guarda qualcosa e alla chiusura del player.
//
//  Un episodio guardato altrove che qui non c'è entra in libreria in
//  streaming (se il file sta sul server), come se lo avessi aperto da Cerca:
//  solo per le voci arrivate dopo l'ultima sincronizzazione, così un titolo
//  tolto dalla libreria non ricompare a ogni avvio.
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

    private static let defaults = UserDefaults.standard
    private static let activeKey = "Curfs.profile.active"
    private static func appliedKey(_ id: String) -> String { "Curfs.profile.appliedAt.\(id)" }

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

    /// Crea il profilo sul server e lo rende attivo. Il minutaggio già
    /// presente su questo dispositivo diventa il suo.
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
        Self.defaults.removeObject(forKey: Self.appliedKey(profile.id))
        if active?.id == profile.id { setActive(nil) }
    }

    /// Entra in un profilo. Da nessun profilo: il minutaggio del dispositivo
    /// si unisce a quello del profilo. Da un altro profilo: prima si salva
    /// quello vecchio sul server, poi il dispositivo riparte dal minutaggio
    /// del nuovo (quello del vecchio resta sul server, non va perso).
    func switchTo(_ profile: UserProfile) async throws {
        guard profile.id != active?.id else { return }
        await waitForPending()
        if let previous = active {
            // Se il vecchio profilo non si riesce a salvare, meglio non
            // cambiare: si perderebbe il minutaggio non ancora inviato.
            try await performSync(for: previous)
            resetLocalProgress()
        }
        Self.defaults.removeObject(forKey: Self.appliedKey(profile.id))
        setActive(profile)
        try await performSync(for: profile)
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
            var remote = try await server.progress(for: profile.id)
            let context = AppModelContainer.shared.mainContext
            let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
            let localNewer = apply(remote, to: items, profileID: profile.id, context: context)
            if !localNewer.isEmpty {
                remote.merge(localNewer)
                try await server.saveProgress(remote, for: profile.id)
            }
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Applica il minutaggio del server alla libreria e restituisce le voci
    /// in cui la libreria è più avanti (da mandare al server).
    private func apply(_ remote: ProgressFile, to items: [MediaItem], profileID: String, context: ModelContext) -> [String: ProgressEntry] {
        var byKey: [String: [MediaItem]] = [:]
        for item in items {
            guard let key = SyncKey.key(for: item) else { continue }
            byKey[key, default: []].append(item)
        }

        let appliedKey = Self.appliedKey(profileID)
        let appliedAt = Int64(Self.defaults.double(forKey: appliedKey))
        var newestApplied = appliedAt
        var changed = false

        for (key, entry) in remote.entries {
            newestApplied = max(newestApplied, entry.at)
            guard let local = byKey[key] else {
                if entry.at > appliedAt, let item = streamingItem(for: entry) {
                    context.insert(item)
                    byKey[key] = [item]
                    changed = true
                }
                continue
            }
            for item in local where (item.lastPlayedAt?.millisecondsSince1970 ?? 0) < entry.at {
                item.playbackPosition = entry.pos
                item.isFinished = entry.done
                item.lastPlayedAt = Date(millisecondsSince1970: entry.at)
                if item.duration <= 0, entry.dur > 0 { item.duration = entry.dur }
                changed = true
            }
        }
        if changed { try? context.save() }
        Self.defaults.set(Double(newestApplied), forKey: appliedKey)

        var newer: [String: ProgressEntry] = [:]
        let base = server?.baseURL
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
                path: group.lazy.compactMap { Self.serverPath(of: $0, base: base) }.first
            )
        }
        return newer
    }

    /// Voce in streaming per un episodio/film guardato su un altro dispositivo.
    private func streamingItem(for entry: ProgressEntry) -> MediaItem? {
        guard let path = entry.path, let base = server?.baseURL else { return nil }
        var url = base
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        let kind = MediaKind(rawValue: entry.kind) ?? .movie
        if kind == .episode, entry.show == nil || entry.season == nil || entry.episode == nil { return nil }
        return MediaItem(
            title: entry.title, kind: kind,
            showName: kind == .episode ? entry.show : nil,
            seasonNumber: kind == .episode ? entry.season : nil,
            episodeNumber: kind == .episode ? entry.episode : nil,
            relativePath: "", remoteURLString: url.absoluteString,
            duration: entry.dur, playbackPosition: entry.pos, isFinished: entry.done,
            lastPlayedAt: Date(millisecondsSince1970: entry.at)
        )
    }

    /// Percorso sul server (non codificato) di un item in streaming.
    private static func serverPath(of item: MediaItem, base: URL?) -> String? {
        guard let remote = item.remoteURLString, let base else { return nil }
        let prefix = base.absoluteString + "/"
        guard remote.hasPrefix(prefix) else { return nil }
        return String(remote.dropFirst(prefix.count)).removingPercentEncoding
    }

    /// Cambio di profilo: il minutaggio del dispositivo era del profilo di prima.
    private func resetLocalProgress() {
        let context = AppModelContainer.shared.mainContext
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items where item.lastPlayedAt != nil || item.playbackPosition > 0 || item.isFinished {
            item.playbackPosition = 0
            item.isFinished = false
            item.lastPlayedAt = nil
        }
        try? context.save()
    }
}
