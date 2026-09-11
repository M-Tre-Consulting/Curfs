//
//  IntroAnalysisStatus.swift
//  Curfs
//
//  Stato osservabile dell'analisi "salta intro" per episodio: serve solo a
//  mostrare all'utente un indicatore (gira mentre analizza, spunta quando è
//  in cache) così sa quando aspettarsi il pulsante alla riproduzione.
//
//  Aggiornato dai punti che fanno il pre-calcolo (avvio app, import, apertura
//  scheda serie, player). Non influenza in alcun modo la logica di analisi.
//
//  "Pronto" (`ready`) e "sigla trovata" (`readyWithIntro`) sono tenuti
//  distinti apposta: un episodio può essere analizzato con successo (in
//  cache, non verrà ricalcolato) SENZA che sia stata trovata una sigla in
//  comune con i vicini (es. un solo vicino disponibile e nessun consenso, o
//  davvero nessun tratto condiviso) — in quel caso è "pronto" nel senso che
//  non c'è altro da calcolare, ma non comparirà nessun pulsante. Prima questa
//  distinzione non c'era e "Salta intro pronto" ✓ compariva anche per stagioni
//  dove in realtà nessun episodio aveva una sigla riconosciuta: confuso,
//  sembrava un bug quando in realtà l'analisi aveva semplicemente concluso
//  "niente da saltare qui".
//

import Foundation
import Observation

enum IntroAnalysisState {
    case pending    // non ancora analizzato
    case analyzing  // analisi in corso adesso
    case ready      // risultato in cache (che abbia trovato una sigla o no)
}

@MainActor
@Observable
final class IntroAnalysisStatus {
    static let shared = IntroAnalysisStatus()
    private init() {}

    private(set) var ready: Set<UUID> = []
    /// Sottoinsieme di `ready`: episodi per cui è stata davvero trovata una
    /// sigla in comune con i vicini (⇒ il pulsante comparirà alla riproduzione).
    private(set) var readyWithIntro: Set<UUID> = []
    private(set) var analyzing: Set<UUID> = []

    func begin(_ id: UUID) {
        guard !ready.contains(id) else { return }
        analyzing.insert(id)
    }

    func finish(_ id: UUID, foundIntro: Bool) {
        analyzing.remove(id)
        ready.insert(id)
        if foundIntro {
            readyWithIntro.insert(id)
        } else {
            readyWithIntro.remove(id)
        }
    }

    /// L'analisi risultava già in cache su disco: pronta senza passare da "analyzing".
    func markCached(_ id: UUID, foundIntro: Bool) {
        analyzing.remove(id)
        ready.insert(id)
        if foundIntro {
            readyWithIntro.insert(id)
        } else {
            readyWithIntro.remove(id)
        }
    }

    /// Dimentica tutto lo stato in memoria: usato insieme a
    /// `IntroCreditsAnalyzer.resetDiskCache()` dal tasto manuale "Ricalcola",
    /// così l'indicatore torna subito a "Analisi sigla… 0/N" invece di
    /// restare a mostrare un "pronto" ormai riferito a una cache cancellata.
    func resetAll() {
        ready.removeAll()
        readyWithIntro.removeAll()
        analyzing.removeAll()
    }

    func state(for id: UUID) -> IntroAnalysisState {
        if ready.contains(id) { return .ready }
        if analyzing.contains(id) { return .analyzing }
        return .pending
    }

    /// Riepilogo per un gruppo di episodi (es. la stagione mostrata).
    /// `withIntro` conta solo quelli per cui è stata davvero trovata una
    /// sigla — è quello che decide se mostrare "Salta intro pronto".
    func summary(for ids: [UUID]) -> (ready: Int, withIntro: Int, total: Int, working: Bool) {
        let readyCount = ids.filter { ready.contains($0) }.count
        let withIntroCount = ids.filter { readyWithIntro.contains($0) }.count
        let working = ids.contains { analyzing.contains($0) } || readyCount < ids.count
        return (readyCount, withIntroCount, ids.count, working)
    }
}
