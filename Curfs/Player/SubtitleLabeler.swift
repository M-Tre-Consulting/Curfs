//
//  SubtitleLabeler.swift
//  Curfs
//
//  Nomi leggibili per le tracce di sottotitoli. I file convertiti da mkv
//  perdono spesso il tag di lingua: AVFoundation le chiama tutte "Lingua
//  sconosciuta" e non si capisce quale scegliere (in un episodio reale: inglese
//  per non udenti, inglese, italiano solo per i dialoghi in dothraki, italiano,
//  lituano — tutte "sconosciute"). Qui:
//  - la lingua, se manca, si riconosce dal testo dei primi sottotitoli
//    (NaturalLanguage, tutto in locale);
//  - "non udenti" se tanti sottotitoli sono rumori tra parentesi;
//  - "parti straniere" se la traccia è molto più corta delle altre (sono
//    quelli "forzati", solo per i dialoghi in un'altra lingua).
//  Solo testo tx3g (quello degli mp4); se qualcosa non torna si ricade su
//  "Sottotitoli N" invece di indovinare.
//

import Foundation
@preconcurrency import AVFoundation
import NaturalLanguage

enum SubtitleLabeler {
    private static let cuesToRead = 40
    private static let readTimeLimit: TimeInterval = 6

    /// Un nome per ogni opzione, `nil` per le tracce vuote (da nascondere:
    /// nei file convertiti ce n'è a volte una di pochi byte che non mostra nulla).
    static func names(for options: [AVMediaSelectionOption], asset: AVAsset) async -> [String?] {
        let fallback: [String] = options.enumerated().map { index, option in
            hasLanguage(option) ? option.displayName : String(localized: "Sottotitoli \(index + 1)")
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .subtitle),
              tracks.count == options.count else { return fallback }

        var sizes: [Int64] = []
        for track in tracks { sizes.append((try? await track.load(.totalSampleDataLength)) ?? 0) }
        let largest = sizes.max() ?? 0

        var names: [String?] = []
        for (index, option) in options.enumerated() {
            if sizes[index] < 200 {
                names.append(nil)
                continue
            }
            let cues = await Task.detached(priority: .utility) { readCues(of: tracks[index], asset: asset) }.value
            var name = fallback[index]
            if !hasLanguage(option), let language = detectLanguage(in: cues),
               let languageName = Locale.current.localizedString(forLanguageCode: language.rawValue) {
                name = languageName.prefix(1).uppercased() + languageName.dropFirst()
            }
            if largest > 0, sizes[index] < largest / 7 {
                name = String(localized: "\(name) (parti straniere)")
            } else if isForHearingImpaired(cues) {
                name = String(localized: "\(name) (non udenti)")
            }
            names.append(name)
        }

        // Due tracce con lo stesso nome restano distinguibili.
        var seen: [String: Int] = [:]
        return names.map { name in
            guard let name else { return nil }
            seen[name, default: 0] += 1
            return seen[name]! > 1 ? "\(name) \(seen[name]!)" : name
        }
    }

    private static func hasLanguage(_ option: AVMediaSelectionOption) -> Bool {
        guard let code = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
        return !code.isEmpty && code != "und"
    }

    /// I primi sottotitoli non vuoti della traccia (tx3g: 2 byte di lunghezza
    /// + testo). Legge solo quella traccia, anche in streaming.
    private static func readCues(of track: AVAssetTrack, asset: AVAsset) -> [String] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        let start = Date()
        var cues: [String] = []
        while cues.count < cuesToRead, Date().timeIntervalSince(start) < readTimeLimit,
              let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 2 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { continue }
            let textLength = Int(bytes[0]) << 8 | Int(bytes[1])
            guard textLength > 0, textLength + 2 <= length else { continue }
            let data = Data(bytes[2..<(2 + textLength)])
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                cues.append(text)
            }
        }
        return cues
    }

    private static func detectLanguage(in cues: [String]) -> NLLanguage? {
        let text = cues.map(stripSoundDescriptions).joined(separator: "\n")
        guard text.count > 40 else { return nil }
        // Lituano e lettone il riconoscitore di sistema non li conosce (il
        // lituano lo scambiava per rumeno): si riconoscono dalle loro lettere.
        // Contano solo se frequenti: un nome come "Māui" non fa lettone un film inglese.
        let letters = text.lowercased().filter(\.isLetter)
        func frequent(_ set: String) -> Bool {
            let count = letters.filter { set.contains($0) }.count
            return count >= 5 && Double(count) / Double(max(letters.count, 1)) > 0.01
        }
        if frequent("ąęėįų") { return NLLanguage("lt") }
        if frequent("āēīķļņģ") { return NLLanguage("lv") }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // Soglia alta: meglio "Sottotitoli N" che una lingua sbagliata.
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value > 0.8 else { return nil }
        return best.key
    }

    private static func isForHearingImpaired(_ cues: [String]) -> Bool {
        guard cues.count >= 10 else { return false }
        let descriptive = cues.filter { cue in
            let trimmed = cue.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = trimmed.filter(\.isLetter)
            let mostlyUppercase = letters.count >= 6
                && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.8
            // Rumori tra parentesi, musica, chi parla ("Varys:" a inizio
            // riga) o tutto maiuscolo: tipici dei sottotitoli per non udenti.
            return trimmed.hasPrefix("(") || trimmed.hasPrefix("[") || trimmed.contains("♪")
                || trimmed.range(of: #"(?m)^[A-Z][A-Za-z'. ]{1,20}:"#, options: .regularExpression) != nil
                || mostlyUppercase
        }
        return Double(descriptive.count) / Double(cues.count) > 0.2
    }

    private static func stripSoundDescriptions(_ cue: String) -> String {
        cue.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
    }
}
