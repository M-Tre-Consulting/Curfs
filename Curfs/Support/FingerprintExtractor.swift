//
//  FingerprintExtractor.swift
//  Curfs
//
//  Calcola l'impronta audio di un episodio (vedi AudioFingerprint) nella
//  finestra iniziale e in quella finale, per ogni traccia audio, e la mette in
//  cache su disco: la decodifica dell'audio va fatta una volta sola per episodio.
//

import Foundation
@preconcurrency import AVFoundation

actor FingerprintExtractor {
    /// Ampiezza massima della finestra iniziale. Larga perché il PRIMO
    /// episodio di una serie spesso ha un cold open lungo e la sigla parte
    /// molto più avanti che negli altri (visto con un pilot reale: 7:15).
    private let maxIntroWindow: Double = 600
    /// Ampiezza massima della finestra finale.
    private let maxCreditsWindow: Double = 300
    /// Sotto questa durata l'episodio è troppo corto per avere sigla/coda.
    private let minDuration: Double = 90
    /// Le tracce audio oltre queste non si leggono (tempo e spazio).
    private let maxTracks = 3

    func fingerprint(for item: MediaItem) async -> EpisodeFingerprint? {
        let duration = item.duration
        guard duration >= minDuration, !item.isRemote else { return nil }

        if let cached = FingerprintStorage.load(for: item.id), cached.duration == duration {
            return cached
        }

        let asset = AVURLAsset(url: item.fileURL)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty else { return nil }
        let tracks = Array(audio.prefix(maxTracks))
        var languages: [String] = []
        for (index, track) in tracks.enumerated() {
            let code = (try? await track.load(.languageCode)) ?? nil
            languages.append(code.flatMap { $0 == "und" ? nil : $0 } ?? "track\(index)")
        }

        let introWindow = min(maxIntroWindow, duration * 0.40)
        let creditsStart = max(duration - min(maxCreditsWindow, duration * 0.35), introWindow)
        guard let intro = try? await AudioFingerprint.codes(asset: asset, tracks: tracks, from: 0, to: introWindow),
              let credits = try? await AudioFingerprint.codes(asset: asset, tracks: tracks, from: creditsStart, to: duration),
              intro.count == credits.count
        else { return nil }

        // Interrotto a metà: l'impronta è parziale. Salvarla la farebbe passare
        // per valida (per sempre, finché la durata non cambia) e l'episodio
        // risulterebbe "senza sigla" anche per i vicini.
        guard !Task.isCancelled else { return nil }

        let fingerprint = EpisodeFingerprint(
            duration: duration,
            creditsStart: creditsStart,
            tracks: tracks.indices.map {
                .init(language: languages[$0], intro: intro[$0].littleEndianData, credits: credits[$0].littleEndianData)
            }
        )
        FingerprintStorage.save(fingerprint, for: item.id)
        return fingerprint
    }

    /// Precalcola e mette in cache l'impronta senza restituire nulla: usato
    /// per scaldare la cache dell'episodio successivo mentre si guarda quello
    /// corrente, così il "salta intro" è pronto appena si passa oltre.
    func prewarm(_ item: MediaItem) async {
        _ = await fingerprint(for: item)
    }
}
