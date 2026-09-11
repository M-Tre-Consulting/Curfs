//
//  MediaDurationMeasurer.swift
//  Curfs
//
//  Misura la durata reale di un file video appena scritto su disco (import
//  locale o download remoto). Subito dopo la copia/scrittura la lettura può
//  fallire in modo transitorio: ritentiamo un po' di volte prima di
//  arrenderci e restituire 0 (il player ritenterà comunque più avanti).
//

import Foundation
@preconcurrency import AVFoundation

nonisolated enum MediaDurationMeasurer {
    static func measure(at url: URL) async -> Double {
        for attempt in 0..<4 {
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds >= 1 {
                return seconds
            }
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return 0
    }
}
