//
//  RemoteSubtitleReader.swift
//  Curfs
//
//  I sottotitoli tx3g di un mp4 in streaming, letti con richieste Range.
//  AVAssetReader con un URL remoto rifiuta di partire ("non-local URL"), e
//  quasi tutto si guarda dal server: qui si scarica solo il `moov` (indice
//  del file, all'inizio grazie a faststart), si ricavano tempi, dimensioni e
//  posizioni dei campioni della traccia di sottotitoli e si chiedono solo i
//  byte delle battute nel tratto che serve (pochi KB). L'indice resta in
//  memoria per URL: le domande successive scaricano solo le battute nuove.
//

import Foundation

actor RemoteSubtitleReader {
    static let shared = RemoteSubtitleReader()

    /// Una traccia di sottotitoli: per ogni battuta tempo (s), posizione e dimensione nel file.
    struct Track: Sendable {
        let times: [Double]
        let offsets: [UInt64]
        let sizes: [Int]
        var totalSize: Int { sizes.reduce(0, +) }
    }

    private var indexes: [URL: [Track]] = [:]
    private static let maxMoovSize: UInt64 = 24 << 20

    func lines(url: URL, headers: [String: String], preferredTrack: Int?, from start: Double, to end: Double) async -> [DialogueReader.Line] {
        let tracks: [Track]
        if let cached = indexes[url] {
            tracks = cached
        } else {
            guard let loaded = await loadIndex(url: url, headers: headers) else { return [] }
            indexes[url] = loaded
            tracks = loaded
        }
        let usable = tracks.indices.filter { tracks[$0].totalSize >= 200 }
        guard let chosen = (preferredTrack.flatMap { usable.contains($0) ? $0 : nil })
                ?? usable.max(by: { tracks[$0].totalSize < tracks[$1].totalSize }) else { return [] }
        let track = tracks[chosen]

        let wanted = track.times.indices.filter { track.times[$0] >= start && track.times[$0] <= end && track.sizes[$0] > 2 }
        guard !wanted.isEmpty else { return [] }

        // Battute attaccate nel file → una richiesta sola.
        var ranges: [(offset: UInt64, length: Int, samples: [Int])] = []
        for index in wanted {
            if var last = ranges.last, last.offset + UInt64(last.length) == track.offsets[index] {
                last.length += track.sizes[index]
                last.samples.append(index)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append((track.offsets[index], track.sizes[index], [index]))
            }
        }

        var texts: [Int: String] = [:]
        await withTaskGroup(of: [(Int, String)].self) { group in
            for range in ranges {
                group.addTask {
                    guard let data = await Self.fetch(url: url, headers: headers, offset: range.offset, length: range.length) else { return [] }
                    var result: [(Int, String)] = []
                    var cursor = 0
                    for sample in range.samples {
                        let size = track.sizes[sample]
                        guard cursor + size <= data.count else { break }
                        if let text = DialogueReader.decodeTx3g(data.subdata(in: cursor..<(cursor + size))) {
                            result.append((sample, text))
                        }
                        cursor += size
                    }
                    return result
                }
            }
            for await chunk in group {
                for (sample, text) in chunk { texts[sample] = text }
            }
        }

        var lines: [DialogueReader.Line] = []
        for index in wanted {
            guard let text = texts[index], text != lines.last?.text else { continue }
            lines.append(DialogueReader.Line(time: track.times[index], text: text))
        }
        return lines
    }

    // MARK: - Indice

    private func loadIndex(url: URL, headers: [String: String]) async -> [Track]? {
        // Si scorrono le scatole di primo livello (16 byte di intestazione a
        // testa) finché non si trova il moov.
        var offset: UInt64 = 0
        for _ in 0..<12 {
            guard let header = await Self.fetch(url: url, headers: headers, offset: offset, length: 16),
                  header.count >= 8 else { return nil }
            var size = UInt64(header.u32(0))
            let type = header.fourCC(4)
            if size == 1, header.count >= 16 { size = header.u64(8) }
            guard size >= 8 else { return nil }
            if type == "moov" {
                guard size <= Self.maxMoovSize,
                      let moov = await Self.fetch(url: url, headers: headers, offset: offset, length: Int(size)) else { return nil }
                return Self.subtitleTracks(inMoov: moov)
            }
            offset += size
        }
        return nil
    }

    static func subtitleTracks(inMoov moov: Data) -> [Track] {
        var tracks: [Track] = []
        guard let moovBody = boxes(in: moov, range: 0..<moov.count).first(where: { $0.type == "moov" })?.body else { return [] }
        for trak in boxes(in: moov, range: moovBody) where trak.type == "trak" {
            guard let mdia = child(moov, of: trak.body, "mdia"),
                  let hdlr = child(moov, of: mdia, "hdlr"), hdlr.count >= 12,
                  ["sbtl", "text", "subt"].contains(moov.fourCC(hdlr.lowerBound + 8)),
                  let mdhd = child(moov, of: mdia, "mdhd"),
                  let minf = child(moov, of: mdia, "minf"),
                  let stbl = child(moov, of: minf, "stbl"),
                  let stsd = child(moov, of: stbl, "stsd"), stsd.count >= 16,
                  moov.fourCC(stsd.lowerBound + 12) == "tx3g",
                  let stts = child(moov, of: stbl, "stts"),
                  let stsc = child(moov, of: stbl, "stsc"),
                  let stsz = child(moov, of: stbl, "stsz") else { continue }
            let chunkOffsets: [UInt64]
            if let stco = child(moov, of: stbl, "stco") {
                let count = Int(moov.u32(stco.lowerBound + 4))
                chunkOffsets = (0..<count).map { UInt64(moov.u32(stco.lowerBound + 8 + $0 * 4)) }
            } else if let co64 = child(moov, of: stbl, "co64") {
                let count = Int(moov.u32(co64.lowerBound + 4))
                chunkOffsets = (0..<count).map { moov.u64(co64.lowerBound + 8 + $0 * 8) }
            } else { continue }

            let version = moov[mdhd.lowerBound]
            let timescale = Double(moov.u32(mdhd.lowerBound + (version == 1 ? 20 : 12)))
            guard timescale > 0 else { continue }

            // Dimensioni.
            let fixedSize = Int(moov.u32(stsz.lowerBound + 4))
            let sampleCount = Int(moov.u32(stsz.lowerBound + 8))
            guard sampleCount > 0, sampleCount < 200_000 else { continue }
            let sizes = fixedSize != 0
                ? Array(repeating: fixedSize, count: sampleCount)
                : (0..<sampleCount).map { Int(moov.u32(stsz.lowerBound + 12 + $0 * 4)) }

            // Tempi.
            var times: [Double] = []
            times.reserveCapacity(sampleCount)
            var clock: UInt64 = 0
            for entry in 0..<Int(moov.u32(stts.lowerBound + 4)) {
                let base = stts.lowerBound + 8 + entry * 8
                let count = Int(moov.u32(base)), delta = UInt64(moov.u32(base + 4))
                for _ in 0..<count where times.count < sampleCount {
                    times.append(Double(clock) / timescale)
                    clock += delta
                }
            }

            // Posizioni: campioni per chunk (stsc) + inizio di ogni chunk (stco).
            let stscCount = Int(moov.u32(stsc.lowerBound + 4))
            let runs: [(firstChunk: Int, perChunk: Int)] = (0..<stscCount).map {
                let base = stsc.lowerBound + 8 + $0 * 12
                return (Int(moov.u32(base)), Int(moov.u32(base + 4)))
            }
            var offsets: [UInt64] = []
            offsets.reserveCapacity(sampleCount)
            var sample = 0
            for (chunkIndex, chunkStart) in chunkOffsets.enumerated() where sample < sampleCount {
                let chunkNumber = chunkIndex + 1
                let perChunk = runs.last(where: { $0.firstChunk <= chunkNumber })?.perChunk ?? 1
                var position = chunkStart
                for _ in 0..<perChunk where sample < sampleCount {
                    offsets.append(position)
                    position += UInt64(sizes[sample])
                    sample += 1
                }
            }
            guard times.count == sampleCount, offsets.count == sampleCount else { continue }
            tracks.append(Track(times: times, offsets: offsets, sizes: sizes))
        }
        return tracks
    }

    // MARK: - Scatole mp4

    private struct Box {
        let type: String
        /// Contenuto (dopo l'intestazione); per le "full box" inizia da versione/flag.
        let body: Range<Int>
    }

    private static func boxes(in data: Data, range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            var size = Int(data.u32(cursor))
            var header = 8
            if size == 1, cursor + 16 <= range.upperBound {
                size = Int(data.u64(cursor + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - cursor
            }
            guard size >= header, cursor + size <= range.upperBound else { break }
            result.append(Box(type: data.fourCC(cursor + 4), body: (cursor + header)..<(cursor + size)))
            cursor += size
        }
        return result
    }

    private static func child(_ data: Data, of range: Range<Int>, _ type: String) -> Range<Int>? {
        boxes(in: data, range: range).first { $0.type == type }?.body
    }

    // MARK: - Rete

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private static func fetch(url: URL, headers: [String: String], offset: UInt64, length: Int) async -> Data? {
        guard length > 0 else { return Data() }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        // Solo 206: un server senza Range manderebbe il video intero.
        return status == 206 ? data : nil
    }
}

nonisolated private extension Data {
    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        let i = startIndex + at
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) << 32 | UInt64(u32(at + 4)) }

    func fourCC(_ at: Int) -> String {
        guard at >= 0, at + 4 <= count else { return "" }
        let i = startIndex + at
        return String(bytes: self[i..<(i + 4)], encoding: .ascii) ?? ""
    }
}
