//
//  VideoMatchVerifier.swift
//  Curfs
//
//  Seconda metà del riconoscimento della sigla: l'audio (AudioFingerprint)
//  dice DOVE i due episodi hanno un tratto in comune e con quale sfalsamento,
//  a 0,1 s; qui si confrontano i fotogrammi negli stessi istanti dei due
//  episodi (sfalsamento esatto ⇒ stesso fotogramma, non due inquadrature a
//  mezzo secondo di distanza come col vecchio campionamento a 1,5 s).
//  Serve a due cose:
//  - conferma: una musica che torna in scene diverse non è la sigla;
//  - bordi: l'inizio è il primo fotogramma uguale, la fine il primo diverso
//    dopo la sigla (le dissolvenze al nero ci stanno dentro), così il salto
//    atterra sulla prima inquadratura dell'episodio.
//

import Foundation
@preconcurrency import AVFoundation

nonisolated enum VideoMatchVerifier {
    private static let step = 0.5
    /// Quanto guardare prima e dopo il tratto trovato dall'audio.
    private static let margin = 8.0
    /// Bit diversi (su 64) perché due fotogrammi siano lo stesso: allo stesso
    /// istante esatto restano solo le differenze di codifica.
    private static let sameFrameBits = 10

    private enum Frame { case same, different, flat }

    /// - Parameters:
    ///   - pieces: il tratto in comune secondo l'audio, in secondi di `mine`,
    ///     a pezzi ognuno col suo sfalsamento (secondi di `mine` − di `theirs`).
    /// - Returns: il tratto rifinito, quello dell'audio se le immagini non
    ///   dicono niente (tutto nero), `nil` se le immagini sono diverse.
    static func verify(mine: URL, theirs: URL, pieces: [(range: ClosedRange<Double>, offset: Double)]) async -> ClosedRange<Double>? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        let range = first.range.lowerBound...last.range.upperBound
        func offset(at time: Double) -> Double {
            pieces.first { $0.range.contains(time) }?.offset
                ?? pieces.min { distance($0.range, time) < distance($1.range, time) }!.offset
        }
        let times = stride(from: max(0, range.lowerBound - margin), through: range.upperBound + margin, by: step)
            .filter { $0 - offset(at: $0) >= 0 }
        guard !times.isEmpty else { return range }
        let mineHashes = await hashes(of: mine, at: times)
        let theirHashes = await hashes(of: theirs, at: times.map { $0 - offset(at: $0) })
        guard !Task.isCancelled, mineHashes.count == times.count, theirHashes.count == times.count else { return range }

        let frames: [Frame] = times.indices.map { index in
            guard let a = mineHashes[index], let b = theirHashes[index] else { return .flat }
            return FrameHasher.hammingDistance(a, b) <= sameFrameBits ? .same : .different
        }

        let inside = times.indices.filter { range.contains(times[$0]) }
        let same = inside.filter { frames[$0] == .same }.count
        let different = inside.filter { frames[$0] == .different }.count
        // Quasi tutto nero/tinta unita: le immagini non confermano né smentiscono.
        guard same + different >= 6 else { return range }
        // Una musica che torna su scene diverse non ha fotogrammi uguali. Una
        // sigla sì, anche quando una parte cambia da un episodio all'altro (la
        // mappa di Game of Thrones): basta un quarto di fotogrammi uguali.
        guard same >= 4, Double(same) / Double(same + different) >= 0.25 else { return nil }

        // Inizio: il primo fotogramma uguale, se cade entro 10 s dall'inizio
        // della musica (che a volte attacca sull'ultima scena prima della
        // sigla); più in là vuol dire che i primi secondi della sigla cambiano
        // tra episodi e vale l'audio.
        let firstSame = times.first { time in frames[times.firstIndex(of: time)!] == .same }!
        let start = firstSame <= range.lowerBound + 10 ? firstSame : range.lowerBound

        // Fine: dopo l'ultimo fotogramma uguale vicino alla fine della musica,
        // compresi i neri che seguono, mai prima della fine della musica.
        var end = range.upperBound
        if let lastSame = times.indices.last(where: { frames[$0] == .same && times[$0] >= range.upperBound - 10 }) {
            var index = lastSame
            while index + 1 < times.count, frames[index + 1] == .flat { index += 1 }
            end = max(end, times[index] + step)
        }
        return start...end
    }

    private static func distance(_ range: ClosedRange<Double>, _ time: Double) -> Double {
        time < range.lowerBound ? range.lowerBound - time : max(0, time - range.upperBound)
    }

    private static func hashes(of url: URL, at times: [Double]) async -> [UInt64?] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = CGSize(width: 48, height: 48)

        var byTime: [Double: UInt64] = [:]
        var answered = 0
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if Task.isCancelled { return [] }
            answered += 1
            if let image = try? result.image, let hash = FrameHasher.hash(image) {
                byTime[result.requestedTime.seconds] = hash
            }
        }
        guard answered == times.count else { return [] }
        return times.map { byTime[CMTime(seconds: $0, preferredTimescale: 600).seconds] }
    }
}
