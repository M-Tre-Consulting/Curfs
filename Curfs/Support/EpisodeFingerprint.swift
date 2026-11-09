//
//  EpisodeFingerprint.swift
//  Curfs
//
//  "Impronta" di un episodio: impronta audio (vedi AudioFingerprint) della
//  finestra iniziale (candidata sigla) e di quella finale (candidata titoli
//  di coda), una per traccia audio, usata da IntroCreditsAnalyzer per
//  confrontare episodi tra loro.
//

import Foundation

struct EpisodeFingerprint: Codable {
    struct Track: Codable {
        /// Lingua della traccia ("ita", "eng"…), per confrontare doppiaggi uguali.
        let language: String
        /// Codici dall'inizio del file (`AudioFingerprint.rate` al secondo).
        let intro: Data
        /// Codici da `creditsStart`.
        let credits: Data

        var introCodes: [UInt32] { [UInt32](littleEndianData: intro) }
        var creditsCodes: [UInt32] { [UInt32](littleEndianData: credits) }
    }

    let duration: Double
    /// Secondo da cui parte la finestra finale.
    let creditsStart: Double
    let tracks: [Track]
}
