//
//  FingerprintStorage.swift
//  Curfs
//
//  Cache su disco delle impronte per episodio (vedi EpisodeFingerprint), per
//  non dover ri-analizzare i fotogrammi di un video ad ogni riproduzione.
//

import Foundation

nonisolated enum FingerprintStorage {
    /// Bump quando cambia il modo in cui i fotogrammi vengono campionati o
    /// hashati (es. il filtro dei fotogrammi degeneri in FrameHasher): così
    /// le impronte già su disco, calcolate col metodo vecchio, vengono
    /// semplicemente ignorate e ricalcolate, invece di restare in cache e
    /// continuare a produrre lo stesso posizionamento sbagliato.
    private static let cacheVersion = 6

    private static func url(for id: UUID) -> URL {
        LibraryStorage.fingerprintsDirectory.appending(path: "\(id.uuidString)-v\(cacheVersion).json")
    }

    static func load(for id: UUID) -> EpisodeFingerprint? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(EpisodeFingerprint.self, from: data)
    }

    static func save(_ fingerprint: EpisodeFingerprint, for id: UUID) {
        guard let data = try? JSONEncoder().encode(fingerprint) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }
}
