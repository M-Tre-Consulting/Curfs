//
//  EpisodeFingerprint.swift
//  Curfs
//
//  "Impronta" di un episodio: hash percettivi campionati nella finestra
//  iniziale (candidata sigla) e in quella finale (candidata titoli di coda),
//  usata da IntroCreditsAnalyzer per confrontare episodi tra loro.
//

import Foundation

struct FrameSample: Codable {
    let time: Double
    let hash: UInt64
}

struct EpisodeFingerprint: Codable {
    let duration: Double
    /// Campioni della finestra iniziale, tempo = secondi dall'inizio.
    let introSamples: [FrameSample]
    /// Campioni della finestra finale, tempo = secondi DALLA FINE (duration - t):
    /// così due episodi di durata diversa restano allineabili sui titoli di coda.
    let creditsSamples: [FrameSample]
}
