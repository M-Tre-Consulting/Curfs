//
//  IntroCreditsStorage.swift
//  Curfs
//
//  Cache su disco del RISULTATO dell'analisi sigla/coda per episodio (non
//  solo le impronte dei singoli episodi): senza questa, il confronto veniva
//  rifatto ad ogni riproduzione contro i vicini del momento, dando risultati
//  leggermente diversi di volta in volta. Con la cache lo stesso episodio dà
//  sempre lo stesso "salta intro", ed è immediato dalla seconda volta.
//
//  La cache è legata a: versione dell'algoritmo, durata dell'episodio, e
//  "firma" dei vicini usati per il confronto (id + durata). Se cambia uno di
//  questi, si ricalcola.
//

import Foundation

struct IntroCreditsCache: Codable {
    let version: Int
    let itemDuration: Double
    let siblingSignature: String
    let introLower: Double?
    let introUpper: Double?
    let creditsLower: Double?
    let creditsUpper: Double?
}

nonisolated enum IntroCreditsStorage {
    private static func url(for id: UUID) -> URL {
        LibraryStorage.fingerprintsDirectory.appending(path: "\(id.uuidString)-introcredits.json")
    }

    static func load(for id: UUID) -> IntroCreditsCache? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(IntroCreditsCache.self, from: data)
    }

    static func save(_ cache: IntroCreditsCache, for id: UUID) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }
}
