//
//  AudioFingerprint.swift
//  Curfs
//
//  Impronta audio di un tratto di video (stile Haitsma-Kalker, la famiglia di
//  Shazam/Chromaprint): 10 codici a 32 bit al secondo, ognuno dice come cambia
//  l'energia tra 33 bande di frequenza rispetto al codice prima. La musica
//  della sigla è identica in ogni episodio, quindi due tratti uguali danno
//  codici quasi uguali allo stesso sfalsamento, a 0,1 s di precisione.
//
//  Prima la sigla si cercava solo con un fotogramma ogni 1,5 s: due episodi
//  non vengono mai campionati negli stessi istanti della sigla e in una sigla
//  montata veloce mezzo secondo di differenza è già un'altra inquadratura ⇒ su
//  The Walking Dead combaciavano 6-14 fotogrammi su ~40 e la sigla non usciva.
//  Ora l'audio trova lo sfalsamento esatto e i fotogrammi servono solo a
//  confermare (vedi IntroCreditsAnalyzer).
//

import Foundation
import Accelerate
@preconcurrency import AVFoundation

nonisolated enum AudioFingerprint {
    static let sampleRate = 8000.0
    private static let windowSize = 2048
    private static let hop = 800
    /// Codici al secondo.
    static let rate = sampleRate / Double(hop)
    private static let bands = 33

    /// Un'impronta per ogni traccia audio del file (i doppiaggi di uno stesso
    /// episodio possono venire da fonti diverse: con l'italiano la sigla di un
    /// episodio non combaciava, con l'inglese sì), tutte lette in una passata.
    static func codes(asset: AVAsset, tracks: [AVAssetTrack], from start: Double, to end: Double) async throws -> [[UInt32]] {
        guard end - start > 1, !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var outputs: [AVAssetReaderTrackOutput] = []
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            outputs.append(output)
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        guard reader.startReading() else { throw reader.error ?? CancellationError() }
        defer { reader.cancelReading() }

        // Le uscite vanno lette a turno: con più tracce, se una resta indietro
        // il lettore si blocca ad aspettarla.
        var samples = [[Float]](repeating: [], count: outputs.count)
        var finished = [Bool](repeating: false, count: outputs.count)
        while finished.contains(false) {
            try Task.checkCancellation()
            for (index, output) in outputs.enumerated() where !finished[index] {
                guard let buffer = output.copyNextSampleBuffer() else { finished[index] = true; continue }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let previous = samples[index].count
                samples[index].append(contentsOf: repeatElement(0, count: count))
                samples[index].withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                                   destination: raw.baseAddress! + previous * MemoryLayout<Float>.size)
                }
            }
        }
        return samples.map(codes(for:))
    }

    static func codes(for samples: [Float]) -> [UInt32] {
        let n = windowSize
        guard samples.count >= n,
              let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)
        else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        // Bande logaritmiche tra 300 e 2000 Hz: dove sta la musica, sopra il rumore.
        let edges = (0...bands).map { Int(300 * pow(2000.0 / 300, Double($0) / Double(bands)) / sampleRate * Double(n)) }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        var frame = [Float](repeating: 0, count: n)
        var previous = [Float](repeating: 0, count: bands)
        var energy = [Float](repeating: 0, count: bands)
        var result: [UInt32] = []
        result.reserveCapacity(samples.count / hop)

        var position = 0
        while position + n <= samples.count {
            samples.withUnsafeBufferPointer { all in
                vDSP.multiply(UnsafeBufferPointer(rebasing: all[position..<position + n]), window, result: &frame)
            }
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP.squareMagnitudes(split, result: &power)
                }
            }
            for band in 0..<bands {
                let upper = max(edges[band + 1], edges[band] + 1)
                energy[band] = power[edges[band]..<upper].reduce(0, +)
            }
            var code: UInt32 = 0
            if position > 0 {
                for bit in 0..<(bands - 1)
                where (energy[bit] - energy[bit + 1]) - (previous[bit] - previous[bit + 1]) > 0 {
                    code |= 1 << UInt32(bit)
                }
            }
            result.append(code)
            swap(&previous, &energy)
            position += hop
        }
        return result
    }

    // MARK: - Confronto

    /// Sotto quanti bit diversi (su 32) due codici contano come "uguali".
    private static let closeBits = 10
    /// Errore medio (frazione di bit, su 2 s) sotto cui un tratto è in comune:
    /// a caso è 0,5; la stessa musica sta tra 0,1 e 0,25 con l'audio buono
    /// (AC3 di The Walking Dead), fino a 0,33 con un AAC più compresso (Game
    /// of Thrones: con 0,3 la sigla si spezzava in pezzi da 15 s).
    private static let maxErrorRate = 0.38
    private static let smoothing = 20 // 2 s

    /// Un pezzo di tratto in comune a sfalsamento costante.
    struct Piece {
        /// Codici di `a` (indici).
        let range: Range<Int>
        /// indice in `a` − indice in `b`.
        let offset: Int
    }

    /// Tratto in comune, anche in più pezzi: la stessa sigla può essere
    /// rimontata (Game of Thrones S1E1: metà sigla a uno sfalsamento, l'altra
    /// metà a 1 s di distanza, perché la mappa mostra città diverse).
    struct Match {
        let pieces: [Piece]
        /// Quanto il picco si stacca dal rumore di fondo (≥ 1,6 per essere preso).
        let strength: Double

        /// Da dove a dove, in codici di `a`.
        var range: Range<Int> { pieces.map(\.range.lowerBound).min()!..<pieces.map(\.range.upperBound).max()! }
        /// Codici davvero in comune.
        var covered: Int { pieces.map(\.range.count).reduce(0, +) }
    }

    /// Prova tutti gli sfalsamenti tra `a` e `b`, prende quello a cui
    /// combaciano di più e, attorno, i pezzi contigui a sfalsamenti vicini.
    static func longestCommon(_ a: [UInt32], _ b: [UInt32], minSeconds: Double) -> Match? {
        guard a.count > smoothing, b.count > smoothing else { return nil }
        // Ogni sfalsamento: quanti codici quasi uguali. ~70 milioni di confronti
        // per 10 minuti contro 10 minuti, pochi centesimi di secondo.
        var scores = [Int](repeating: 0, count: a.count + b.count - 1)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for shift in 0..<scores.count {
                    let offset = shift - (b.count - 1)
                    let lower = max(0, offset), upper = min(a.count, b.count + offset)
                    var count = 0
                    var i = lower
                    while i < upper {
                        if (a[i] ^ b[i - offset]).nonzeroBitCount <= closeBits { count += 1 }
                        i += 1
                    }
                    scores[shift] = count
                }
            }
        }
        guard let peak = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        // Rumore di fondo: quello che si raggiunge per caso (1% più alto degli
        // sfalsamenti lontani dal picco).
        let others = scores.indices.filter { abs($0 - peak) > 150 }.map { scores[$0] }.sorted(by: >)
        let background = Double(max(1, others.isEmpty ? 1 : others[others.count / 100]))
        let strength = Double(scores[peak]) / background
        guard strength >= 1.6, Double(scores[peak]) - background >= 8 * rate else { return nil }

        // Sfalsamenti candidati: il picco e gli altri massimi locali entro 10 s
        // che si staccano dal fondo.
        let mainOffset = peak - (b.count - 1)
        var offsets = [mainOffset]
        for shift in max(0, peak - 100)...min(scores.count - 1, peak + 100) where shift != peak {
            let isLocalMax = (max(0, shift - 3)...min(scores.count - 1, shift + 3)).allSatisfy { scores[$0] <= scores[shift] }
            if isLocalMax, Double(scores[shift]) >= background * 1.3 { offsets.append(shift - (b.count - 1)) }
        }

        // Tutti i pezzi da almeno 3 s, per ogni sfalsamento candidato.
        var pieces: [(piece: Piece, error: Double)] = []
        for offset in offsets { pieces += runs(a, b, offset: offset, minLength: Int(3 * rate)) }
        guard let seed = pieces.filter({ $0.piece.offset == mainOffset }).max(by: { $0.piece.range.count < $1.piece.range.count }) else { return nil }

        // Si parte dal pezzo più lungo allo sfalsamento principale e si
        // attaccano i pezzi che lo continuano (buco ≤ 3 s); dove due pezzi si
        // sovrappongono vince quello già preso.
        var chosen = [seed.piece]
        let gap = Int(3 * rate)
        var added = true
        while added {
            added = false
            let span = chosen.map(\.range.lowerBound).min()!..<chosen.map(\.range.upperBound).max()!
            for candidate in pieces.sorted(by: { $0.error < $1.error }) {
                let range = candidate.piece.range
                guard range.upperBound + gap >= span.lowerBound, range.lowerBound <= span.upperBound + gap else { continue }
                // La parte nuova, fuori da quello che c'è già.
                var fresh: [Range<Int>] = []
                if range.lowerBound < span.lowerBound { fresh.append(range.lowerBound..<min(range.upperBound, span.lowerBound)) }
                if range.upperBound > span.upperBound { fresh.append(max(range.lowerBound, span.upperBound)..<range.upperBound) }
                for part in fresh where part.count >= Int(rate) {
                    chosen.append(Piece(range: part, offset: candidate.piece.offset))
                    added = true
                }
                if added { break }
            }
        }

        let match = Match(pieces: chosen.sorted { $0.range.lowerBound < $1.range.lowerBound }, strength: strength)
        guard Double(match.covered) / rate >= minSeconds else { return nil }
        return match
    }

    /// I tratti a sfalsamento `offset` in cui l'errore medio su 2 s resta basso.
    private static func runs(_ a: [UInt32], _ b: [UInt32], offset: Int, minLength: Int) -> [(piece: Piece, error: Double)] {
        let lower = max(0, offset), upper = min(a.count, b.count + offset)
        guard upper - lower > smoothing else { return [] }
        // ±1 codice (0,1 s) di tolleranza: tra due montaggi della stessa sigla
        // lo sfalsamento può muoversi di un decimo (Game of Thrones S1E1: i
        // primi 20 s della sigla restavano fuori).
        let errors = (lower..<upper).map { i in
            Double((-1...1).compactMap { shift -> Int? in
                let j = i - offset + shift
                return b.indices.contains(j) ? (a[i] ^ b[j]).nonzeroBitCount : nil
            }.min() ?? 32) / 32
        }
        // Media su 2 s, centrata.
        var smooth = [Double](repeating: 1, count: errors.count)
        var sum = 0.0
        for k in errors.indices {
            sum += errors[k]
            if k >= smoothing { sum -= errors[k - smoothing] }
            if k >= smoothing - 1 { smooth[k - smoothing / 2] = sum / Double(smoothing) }
        }
        var result: [(Piece, Double)] = []
        var k = 0
        while k < smooth.count {
            guard smooth[k] < maxErrorRate else { k += 1; continue }
            let start = k
            var total = 0.0
            while k < smooth.count, smooth[k] < maxErrorRate { total += errors[k]; k += 1 }
            if k - start >= minLength {
                result.append((Piece(range: (start + lower)..<(k + lower), offset: offset), total / Double(k - start)))
            }
        }
        return result
    }
}

extension Array where Element == UInt32 {
    /// Per salvare le impronte compatte (JSON le metterebbe numero per numero).
    var littleEndianData: Data {
        var data = Data(capacity: count * 4)
        for value in self { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    init(littleEndianData data: Data) {
        self = stride(from: 0, to: data.count - 3, by: 4).map { index in
            data[data.startIndex + index..<data.startIndex + index + 4].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
    }
}
