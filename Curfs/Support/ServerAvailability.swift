//
//  ServerAvailability.swift
//  Curfs
//
//  Quali voci in streaming della libreria non hanno più il file sul server.
//  Regola voluta dall'utente (2026-11-28): un episodio/film che non c'è più
//  sul server e non è scaricato sul dispositivo NON deve comparire nei
//  Contenuti recenti né nella scheda della serie, nemmeno per un attimo.
//
//  `ProfileSync.removeMissingFromServer` poi li toglie anche dalla libreria
//  e dal profilo (al massimo ogni 2 minuti); questo invece è solo il filtro
//  per le schermate, subito all'apertura, con lo stesso controllo (un elenco
//  JSON per cartella, nel dubbio il file si considera presente).
//

import Foundation
import Observation

@MainActor
@Observable
final class ServerAvailability {
    static let shared = ServerAvailability()

    /// `remoteURLString` delle voci il cui file non c'è più sul server.
    private(set) var missing: Set<String> = []

    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var checking = false

    private init() {}

    /// `false` solo per una voce in streaming il cui file è sparito dal
    /// server. Gli scaricati/importati ci sono sempre: il file è qui.
    func isAvailable(_ item: MediaItem) -> Bool {
        guard let remote = item.remoteURLString else { return true }
        return !missing.contains(remote)
    }

    /// Ricontrolla le voci in streaming (al massimo ogni 30 s, salvo `force`).
    func refresh(_ items: [MediaItem], force: Bool = false) async {
        guard !checking, force || Date.now.timeIntervalSince(lastCheck) > 30 else { return }
        guard let server = ProfileServer() else { return }
        checking = true
        defer { checking = false }
        lastCheck = .now

        var pathsByURL: [String: String] = [:]
        for item in items {
            guard let remote = item.remoteURLString,
                  let path = ProfileSync.serverPath(of: item, base: server.baseURL) else { continue }
            pathsByURL[remote] = path
        }
        guard !pathsByURL.isEmpty else {
            if !missing.isEmpty { missing = [] }
            return
        }
        let gone = await server.missingFiles(Array(Set(pathsByURL.values)))
        let result = Set(pathsByURL.filter { gone.contains($0.value) }.keys)
        if result != missing { missing = result }
    }

    /// Dopo che `ProfileSync` ha trovato e tolto i file spariti.
    func noteMissing(_ urls: some Sequence<String>) {
        let updated = missing.union(urls)
        if updated != missing { missing = updated }
    }
}
