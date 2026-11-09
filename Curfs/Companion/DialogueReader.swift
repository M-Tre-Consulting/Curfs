//
//  DialogueReader.swift
//  Curfs
//
//  I dialoghi degli ultimi minuti prima del punto in cui si è, letti dalla
//  traccia di sottotitoli dentro al file (tx3g, quella degli mp4): è il
//  contesto che permette a Curfs AI di rispondere su "questa scena". Solo il
//  tratto che serve: per i file locali con AVAssetReader (`timeRange`), per
//  lo streaming con RemoteSubtitleReader (AVAssetReader non accetta URL
//  remoti). Senza sottotitoli nel file resta vuoto e si risponde con trame e cast.
//

import Foundation
@preconcurrency import AVFoundation

nonisolated enum DialogueReader {
    struct Line: Sendable {
        let time: Double
        let text: String
    }

    private static let readTimeLimit: TimeInterval = 8

    /// - Parameter preferredTrack: indice della traccia scelta nel player
    ///   (stesso ordine delle tracce del file); senza, la più grande, che di
    ///   solito ha tutti i dialoghi.
    ///   `remote`: URL e header di autenticazione per un video in streaming.
    static func lines(in asset: AVAsset, remote: (url: URL, headers: [String: String])?, preferredTrack: Int?,
                      until end: Double, window: Double = 300) async -> [Line] {
        guard end > 1 else { return [] }
        if let remote {
            return await RemoteSubtitleReader.shared.lines(
                url: remote.url, headers: remote.headers, preferredTrack: preferredTrack,
                from: max(0, end - window), to: end
            )
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .subtitle), !tracks.isEmpty else { return [] }
        var sizes: [Int64] = []
        for track in tracks { sizes.append((try? await track.load(.totalSampleDataLength)) ?? 0) }

        let track: AVAssetTrack
        if let preferredTrack, tracks.indices.contains(preferredTrack), sizes[preferredTrack] >= 200 {
            track = tracks[preferredTrack]
        } else if let largest = sizes.indices.max(by: { sizes[$0] < sizes[$1] }), sizes[largest] >= 200 {
            track = tracks[largest]
        } else {
            return []
        }

        let start = max(0, end - window)
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        return await Task.detached(priority: .userInitiated) {
            read(track: track, asset: asset, range: range)
        }.value
    }

    private static func read(track: AVAssetTrack, asset: AVAsset, range: CMTimeRange) -> [Line] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        let started = Date()
        var lines: [Line] = []
        while Date().timeIntervalSince(started) < readTimeLimit, let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, time <= range.end.seconds,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 2 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { continue }
            guard let text = decodeTx3g(Data(bytes)), text != lines.last?.text else { continue }
            lines.append(Line(time: time, text: text))
        }
        return lines
    }

    /// Un campione tx3g: 2 byte di lunghezza + testo (+ eventuali stili, ignorati).
    static func decodeTx3g(_ sample: Data) -> String? {
        let bytes = [UInt8](sample)
        guard bytes.count > 2 else { return nil }
        let textLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard textLength > 0, textLength + 2 <= bytes.count else { return nil }
        let data = Data(bytes[2..<(2 + textLength)])
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        let text = clean(raw)
        return text.isEmpty ? nil : text
    }

    /// Via i tag di stile (<i>, {\an8}) e gli a capo dentro la stessa battuta.
    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<[^>]+>|\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}
