//
//  DialogueReader.swift
//  Curfs
//
//  I dialoghi degli ultimi minuti prima del punto in cui si è, letti dalla
//  traccia di sottotitoli dentro al file (tx3g, quella degli mp4): è il
//  contesto che permette a Curfs AI di rispondere su "questa scena". Solo il
//  tratto che serve: per i file locali con AVAssetReader (`timeRange`), per
//  lo streaming con RemoteSubtitleReader (AVAssetReader non accetta URL
//  remoti). Si leggono tutte le tracce e si uniscono (vedi `merge`). Senza
//  sottotitoli nel file resta vuoto e si risponde con trame e cast.
//

import Foundation
@preconcurrency import AVFoundation
import NaturalLanguage

nonisolated enum DialogueReader {
    struct Line: Sendable {
        let time: Double
        let text: String
    }

    private static let readTimeLimit: TimeInterval = 8

    /// I dialoghi degli ultimi `window` secondi, da ogni traccia di sottotitoli
    /// del file (stesso ordine delle tracce); poi `merge` li unisce.
    /// - Parameter remote: URL e header di autenticazione per un video in streaming.
    static func tracks(in asset: AVAsset, remote: (url: URL, headers: [String: String])?,
                       until end: Double, window: Double = 300) async -> [Int: [Line]] {
        guard end > 1 else { return [:] }
        let start = max(0, end - window)
        var result: [Int: [Line]] = [:]
        if let remote {
            for index in await RemoteSubtitleReader.shared.usableTracks(url: remote.url, headers: remote.headers).prefix(maxTracks) {
                let lines = await RemoteSubtitleReader.shared.lines(url: remote.url, headers: remote.headers, track: index, from: start, to: end)
                if !lines.isEmpty { result[index] = lines }
            }
            return result
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .subtitle) else { return [:] }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        for (index, track) in tracks.enumerated().prefix(maxTracks) {
            // Le tracce vuote (ce n'è una da 11 byte nei file dell'utente) no.
            guard ((try? await track.load(.totalSampleDataLength)) ?? 0) >= 200 else { continue }
            let lines = await Task.detached(priority: .userInitiated) {
                read(track: track, asset: asset, range: range)
            }.value
            if !lines.isEmpty { result[index] = lines }
        }
        return result
    }

    private static let maxTracks = 6

    // MARK: - Unione delle tracce

    /// Una traccia sola con il meglio di tutte: il testo dalla traccia nella
    /// lingua di chi chiede (niente traduzioni: il modello piccolo rendeva
    /// "ears" con "cuffie"), e dalla traccia per non udenti chi parla
    /// ("GLENN: È Daryl?") e i rumori ("(GUNSHOT)"), che le altre non hanno:
    /// senza, il modello non capiva chi diceva e faceva cosa.
    /// - Parameters:
    ///   - language: nome inglese della lingua ("Italian").
    ///   - preferred: la traccia scelta nel player, se c'è.
    static func merge(_ tracks: [Int: [Line]], language: String, preferred: Int?) -> [Line] {
        guard !tracks.isEmpty else { return [] }
        let indices = tracks.keys.sorted()
        let matching = indices.filter { self.language(of: tracks[$0]!) == language }
        let largest = { (candidates: [Int]) in candidates.max { tracks[$0]!.count < tracks[$1]!.count } }
        let labelScores = tracks.mapValues { $0.filter { speaker(in: $0.text) != nil || isSound($0.text) }.count }
        let labels = indices.filter { labelScores[$0]! >= 3 }.max { labelScores[$0]! < labelScores[$1]! }

        let text: Int
        if let preferred, matching.contains(preferred) {
            text = preferred
        } else if let best = largest(matching) {
            text = best
        } else {
            text = (preferred.flatMap { tracks[$0] != nil ? $0 : nil }) ?? labels ?? largest(indices)!
        }
        var lines = tracks[text]!
        guard let labels, labels != text else { return lines }

        let labelLines = tracks[labels]!
        for index in lines.indices where speaker(in: lines[index].text) == nil {
            let time = lines[index].time
            if let near = labelLines.filter({ abs($0.time - time) <= 1.2 }).min(by: { abs($0.time - time) < abs($1.time - time) }),
               let name = speaker(in: near.text) {
                lines[index] = Line(time: time, text: "\(name): \(lines[index].text)")
            }
        }
        lines += labelLines.filter { isSound($0.text) }
        return lines.sorted { $0.time < $1.time }
    }

    /// "RICK: No, Andrea." → "RICK" (nomi in maiuscolo, come nei sottotitoli per non udenti).
    private static func speaker(in text: String) -> String? {
        guard let match = text.firstMatch(of: /^-?\s*([A-Z][A-Z .'-]{1,24}):/) else { return nil }
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }

    /// Una battuta che è solo un rumore: "(GUNSHOT)", "[SPARO]".
    private static func isSound(_ text: String) -> Bool {
        text.wholeMatch(of: /\s*[\(\[][^\)\]]+[\)\]]\s*/) != nil
    }

    private static func language(of lines: [Line]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.prefix(60).map(\.text).joined(separator: "\n"))
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
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
