//
//  FileNameParser.swift
//  Curfs
//
//  Funzioni pure per capire, dal nome di un file e dalle cartelle che lo
//  contengono, se si tratta di un episodio di una serie (e quale show,
//  stagione, episodio) oppure di un film a sé stante. Nessuna I/O qui dentro:
//  tutta la logica è testabile e isolata dal filesystem.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum FileNameParser {

    // MARK: - Riconoscimento file video

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm",
        "mpg", "mpeg", "3gp", "3g2", "ts", "m2ts", "vob"
    ]

    static func isVideoFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .audiovisualContent) {
            return true
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Estrazione Stagione/Episodio dal nome file

    struct SeasonEpisodeMatch {
        let season: Int
        let episode: Int
        let range: Range<String.Index>
    }

    private static let seasonEpisodePatterns = [
        "[Ss](\\d{1,2})[ ._-]*[Ee](\\d{1,3})",
        "(?<![0-9])(\\d{1,2})[xX](\\d{2,3})(?![0-9])"
    ]

    static func extractSeasonEpisode(_ text: String) -> SeasonEpisodeMatch? {
        for pattern in seasonEpisodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let m = regex.firstMatch(in: text, range: nsRange),
                  let r1 = Range(m.range(at: 1), in: text),
                  let r2 = Range(m.range(at: 2), in: text),
                  let full = Range(m.range, in: text),
                  let s = Int(text[r1]), let e = Int(text[r2]) else { continue }
            return SeasonEpisodeMatch(season: s, episode: e, range: full)
        }
        return nil
    }

    static func textBefore(_ match: SeasonEpisodeMatch, in text: String) -> String {
        String(text[text.startIndex..<match.range.lowerBound])
    }

    // MARK: - Riconoscimento cartelle "Stagione"

    private static let seasonWordRegex = try! NSRegularExpression(
        pattern: "(?:season|stagione|serie)\\D{0,3}(\\d{1,2})",
        options: .caseInsensitive
    )
    private static let seasonAbbrevRegex = try! NSRegularExpression(
        pattern: "(?:^|[^a-zA-Z0-9])[Ss](\\d{1,2})(?:[^a-zA-Z0-9]|$)"
    )

    static func seasonNumber(inFolderName name: String) -> Int? {
        for regex in [seasonWordRegex, seasonAbbrevRegex] {
            let nsRange = NSRange(name.startIndex..., in: name)
            if let m = regex.firstMatch(in: name, range: nsRange),
               let r = Range(m.range(at: 1), in: name),
               let n = Int(name[r]) {
                return n
            }
        }
        return nil
    }

    /// Indice della prima cartella, nella catena di cartelle (dalla più esterna
    /// alla più interna), che sembra rappresentare una stagione.
    static func seasonFolderIndex(_ folders: [String]) -> Int? {
        for (idx, folder) in folders.enumerated() {
            if seasonNumber(inFolderName: folder) != nil { return idx }
        }
        return nil
    }

    /// Deduce il nome della serie a partire dalla catena di cartelle.
    /// `rootFallback` è il nome della cartella immediatamente sopra la prima
    /// cartella della catena, usato quando la cartella "Stagione" è già la
    /// prima cartella disponibile (quindi lo show non compare in `folders`).
    static func bestShowName(folders: [String], seasonHintIndex: Int?, rootFallback: String) -> String {
        if let idx = seasonHintIndex {
            if idx > 0 { return cleanTitle(folders[idx - 1]) }
            return cleanTitle(rootFallback)
        }
        if let last = folders.last { return cleanTitle(last) }
        return cleanTitle(rootFallback)
    }

    // MARK: - Pulizia titoli

    private static let releaseTagsRegex = try! NSRegularExpression(
        pattern: "\\b(1080p|720p|2160p|480p|4k|x264|x265|h264|h265|hevc|web[- ]?dl|webrip|bluray|brrip|bdrip|hdrip|dvdrip|remux|proper|repack|extended|uncut|multi|dl|ita|eng|aac\\d*|ac3|dts)\\b",
        options: .caseInsensitive
    )

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)

        let nsRange = NSRange(s.startIndex..., in: s)
        s = releaseTagsRegex.stringByReplacingMatches(in: s, range: nsRange, withTemplate: "")

        s = s.replacingOccurrences(of: "-{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))

        return s.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }

    static func cleanEpisodeTitle(_ raw: String) -> String {
        var s = raw
        for pattern in seasonEpisodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: nsRange, withTemplate: "")
        }
        return cleanTitle(s)
    }

    static func sanitizeFilename(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "File" : s
    }
}
