//
//  FingerprintExtractor.swift
//  Curfs
//
//  Campiona i fotogrammi di un episodio nella finestra iniziale e finale e
//  ne calcola l'hash percettivo (vedi FrameHasher), producendo un'impronta
//  (EpisodeFingerprint) confrontabile con quella di altri episodi. Il
//  risultato viene messo in cache su disco: l'estrazione (che richiede di
//  decodificare fotogrammi dal video) va fatta una volta sola per episodio.
//
//  La finestra iniziale è campionata più fitta di quella finale: lì la
//  precisione del bordo conta (è dove atterra il "salta intro"), mentre la
//  coda serve solo a capire "siamo ai titoli di coda".
//

import Foundation
@preconcurrency import AVFoundation

actor FingerprintExtractor {
    /// Passo di campionamento della finestra iniziale (candidata sigla).
    /// 1,5 s: abbastanza fitto da agganciare bene i bordi del tratto (con
    /// l'estensione di un passo lato analizzatore), abbastanza largo da
    /// coprire una finestra ampia senza esplodere di fotogrammi.
    private let introInterval: Double = 1.5
    /// Passo di campionamento della finestra finale (candidata coda): più
    /// largo, basta a riconoscere di essere nei titoli di coda.
    private let creditsInterval: Double = 2.0
    /// Ampiezza massima della finestra iniziale. Larga (8 min, era 5) perché
    /// il PRIMO episodio di una serie spesso ha un cold open lungo e la
    /// sigla parte molto più avanti che negli altri episodi — con una
    /// finestra stretta la sigla dell'ep. 1 cadrebbe fuori e non verrebbe
    /// rilevata (visto con un pilot reale: cold open di 7:15).
    private let maxIntroWindow: Double = 480
    /// Ampiezza massima della finestra finale.
    private let maxCreditsWindow: Double = 180
    /// Sotto questa durata l'episodio è troppo corto per avere sigla/coda
    /// distinguibili con questo approccio.
    private let minDuration: Double = 90

    func fingerprint(for item: MediaItem) async -> EpisodeFingerprint? {
        let duration = item.duration
        guard duration >= minDuration else { return nil }

        if let cached = FingerprintStorage.load(for: item.id), cached.duration == duration {
            return cached
        }

        let asset = AVURLAsset(url: item.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 48, height: 48)

        let introWindow = min(maxIntroWindow, duration * 0.40)
        let creditsWindow = min(maxCreditsWindow, duration * 0.35)
        guard introWindow > 10, creditsWindow > 10 else { return nil }

        let introTimes = stride(from: 0.0, to: introWindow, by: introInterval).map { $0 }
        let creditsStart = max(duration - creditsWindow, introWindow)
        let creditsTimes = stride(from: creditsStart, to: duration, by: creditsInterval).map { $0 }

        let introSamples = await sample(times: introTimes, generator: generator) { $0 }
        let creditsSamples = await sample(times: creditsTimes, generator: generator) { duration - $0 }

        let fingerprint = EpisodeFingerprint(duration: duration, introSamples: introSamples, creditsSamples: creditsSamples)
        FingerprintStorage.save(fingerprint, for: item.id)
        return fingerprint
    }

    /// Precalcola e mette in cache l'impronta senza restituire nulla: usato
    /// per scaldare la cache dell'episodio successivo mentre si guarda quello
    /// corrente, così il "salta intro" è pronto appena si passa oltre.
    func prewarm(_ item: MediaItem) async {
        _ = await fingerprint(for: item)
    }

    private func sample(
        times: [Double],
        generator: AVAssetImageGenerator,
        storedTime: (Double) -> Double
    ) async -> [FrameSample] {
        guard !times.isEmpty else { return [] }
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

        var results: [FrameSample] = []
        results.reserveCapacity(times.count)

        // API batch: decodifica la lista di istanti in un'unica passata, molto
        // più rapida di un `image(at:)` alla volta.
        for await result in generator.images(for: cmTimes) {
            if Task.isCancelled { break }
            guard let image = try? result.image,
                  let hash = FrameHasher.hash(image) else { continue }
            results.append(FrameSample(time: storedTime(result.requestedTime.seconds), hash: hash))
        }
        return results
    }
}
