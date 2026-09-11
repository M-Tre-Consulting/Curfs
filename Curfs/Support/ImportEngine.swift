//
//  ImportEngine.swift
//  Curfs
//
//  Riceve gli URL scelti dall'utente nel picker di Files (file singoli e/o
//  intere cartelle), li espande, capisce se rappresentano film o episodi di
//  una serie guardando i nomi delle cartelle/file, copia i video dentro il
//  container dell'app e restituisce dei record pronti da salvare in SwiftData.
//
//  Gira su un actor dedicato così tutta la copia (I/O pesante) e il calcolo
//  della durata restano fuori dal Main Actor e non bloccano l'interfaccia.
//

import Foundation
@preconcurrency import AVFoundation

struct ImportedItem: Sendable {
    var title: String
    var kind: MediaKind
    var showName: String?
    var season: Int?
    var episode: Int?
    var relativePath: String
    var duration: Double
}

struct ImportProgressUpdate: Sendable {
    var completed: Int
    var total: Int
    var currentName: String
}

actor ImportEngine {

    private struct RawEntry {
        let sourceURL: URL
        let pickedAsFolder: Bool
        let relativeFolders: [String]
        let rootName: String
    }

    private struct WorkItem {
        let entry: RawEntry
        var kind: MediaKind
        var title: String
        var showName: String?
        var season: Int?
        var episode: Int?
    }

    /// Punto d'ingresso: gli URL arrivano già "accessibili" (security scope
    /// avviata dal chiamante sul Main Actor) e restano validi per tutta la
    /// durata di questa funzione.
    func importURLs(
        _ pickedURLs: [URL],
        onProgress: @escaping @Sendable (ImportProgressUpdate) -> Void
    ) async -> [ImportedItem] {
        let entries = collectEntries(pickedURLs)
        guard !entries.isEmpty else { return [] }

        var work = classify(entries)
        resolveGroupsAndMovies(&work)

        var results: [ImportedItem] = []
        let total = work.count
        for (index, item) in work.enumerated() {
            if let imported = try? await copyAndMeasure(item) {
                results.append(imported)
            }
            onProgress(ImportProgressUpdate(completed: index + 1, total: total, currentName: item.entry.sourceURL.lastPathComponent))
        }
        return results
    }

    // MARK: - Passo 1: espansione cartelle -> file video grezzi

    private func collectEntries(_ rawPickedURLs: [URL]) -> [RawEntry] {
        guard !rawPickedURLs.isEmpty else { return [] }

        // Normalizziamo subito i path (es. /var vs /private/var su iOS/macOS):
        // senza questo, il confronto "prefisso" tra la root e i file trovati
        // dall'enumeratore può fallire silenziosamente e far perdere le
        // cartelle superiori (nome show) dal calcolo del percorso relativo.
        let pickedURLs = rawPickedURLs.map { $0.resolvingSymlinksInPath() }

        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }

        let container: URL
        if pickedURLs.count == 1 {
            container = pickedURLs[0]
        } else {
            let refs = pickedURLs.map { isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
            var common = refs[0].pathComponents
            for u in refs.dropFirst() {
                let c = u.pathComponents
                var i = 0
                while i < common.count, i < c.count, common[i] == c[i] { i += 1 }
                common = Array(common[0..<i])
            }
            container = common.isEmpty ? refs[0] : URL(fileURLWithPath: common.joined(separator: "/"))
        }
        let root = container.deletingLastPathComponent()
        let rootComponents = root.pathComponents
        let rootName = root.lastPathComponent

        func relativeFolders(for fileURL: URL) -> [String] {
            let parentComponents = fileURL.deletingLastPathComponent().pathComponents
            guard parentComponents.count >= rootComponents.count,
                  Array(parentComponents.prefix(rootComponents.count)) == rootComponents else {
                return [fileURL.deletingLastPathComponent().lastPathComponent]
            }
            return Array(parentComponents.dropFirst(rootComponents.count))
        }

        var entries: [RawEntry] = []
        for picked in pickedURLs {
            if isDirectory(picked) {
                if let en = FileManager.default.enumerator(
                    at: picked,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let rawFileURL as URL in en {
                        guard FileNameParser.isVideoFile(rawFileURL) else { continue }
                        let fileURL = rawFileURL.resolvingSymlinksInPath()
                        entries.append(RawEntry(
                            sourceURL: fileURL,
                            pickedAsFolder: true,
                            relativeFolders: relativeFolders(for: fileURL),
                            rootName: rootName
                        ))
                    }
                }
            } else if FileNameParser.isVideoFile(picked) {
                entries.append(RawEntry(
                    sourceURL: picked,
                    pickedAsFolder: pickedURLs.count > 1,
                    relativeFolders: relativeFolders(for: picked),
                    rootName: rootName
                ))
            }
        }
        return entries
    }

    // MARK: - Passo 2: classificazione film/episodio

    private func classify(_ entries: [RawEntry]) -> [WorkItem] {
        entries.map { entry in
            let filenameNoExt = entry.sourceURL.deletingPathExtension().lastPathComponent

            if let match = FileNameParser.extractSeasonEpisode(filenameNoExt) {
                let sIdx = FileNameParser.seasonFolderIndex(entry.relativeFolders)
                let showFromFolder = entry.pickedAsFolder
                    ? FileNameParser.bestShowName(folders: entry.relativeFolders, seasonHintIndex: sIdx, rootFallback: entry.rootName)
                    : nil
                let showFromFilename = FileNameParser.textBefore(match, in: filenameNoExt)
                let cleanedFromFilename = FileNameParser.cleanTitle(showFromFilename)
                let showName = showFromFolder ?? (cleanedFromFilename.isEmpty ? "Serie" : cleanedFromFilename)

                let title = FileNameParser.cleanEpisodeTitle(filenameNoExt)
                return WorkItem(
                    entry: entry,
                    kind: .episode,
                    title: title.isEmpty ? "Episodio \(match.episode)" : title,
                    showName: showName,
                    season: match.season,
                    episode: match.episode
                )
            }

            if entry.pickedAsFolder, !entry.relativeFolders.isEmpty {
                let sIdx = FileNameParser.seasonFolderIndex(entry.relativeFolders)
                let season = sIdx.flatMap { FileNameParser.seasonNumber(inFolderName: entry.relativeFolders[$0]) } ?? 1
                let showName = FileNameParser.bestShowName(folders: entry.relativeFolders, seasonHintIndex: sIdx, rootFallback: entry.rootName)
                return WorkItem(
                    entry: entry,
                    kind: .episode,
                    title: FileNameParser.cleanTitle(filenameNoExt),
                    showName: showName,
                    season: season,
                    episode: nil
                )
            }

            return WorkItem(
                entry: entry,
                kind: .movie,
                title: FileNameParser.cleanTitle(filenameNoExt),
                showName: nil,
                season: nil,
                episode: nil
            )
        }
    }

    // MARK: - Passo 3: raggruppa gli episodi "candidati" per show+stagione;
    // se un gruppo ha un solo file, non è una serie: lo riclassifica come film.

    private func resolveGroupsAndMovies(_ work: inout [WorkItem]) {
        var groups: [String: [Int]] = [:]
        for (i, w) in work.enumerated() where w.kind == .episode && w.episode == nil {
            let key = "\(w.showName ?? "")|\(w.season ?? 1)"
            groups[key, default: []].append(i)
        }

        for (_, indices) in groups {
            if indices.count == 1 {
                let i = indices[0]
                work[i].kind = .movie
                work[i].title = FileNameParser.cleanTitle(work[i].entry.sourceURL.deletingPathExtension().lastPathComponent)
                work[i].showName = nil
                work[i].season = nil
                work[i].episode = nil
            } else {
                let sorted = indices.sorted {
                    work[$0].entry.sourceURL.lastPathComponent.localizedStandardCompare(work[$1].entry.sourceURL.lastPathComponent) == .orderedAscending
                }
                for (n, idx) in sorted.enumerated() {
                    work[idx].episode = n + 1
                }
            }
        }
    }

    // MARK: - Passo 4: copia su disco + durata reale

    private func copyAndMeasure(_ item: WorkItem) async throws -> ImportedItem {
        let relativePath = try copyToLibrary(item)
        let destURL = LibraryStorage.mediaDirectory.appending(path: relativePath)
        let seconds = await MediaDurationMeasurer.measure(at: destURL)
        return ImportedItem(
            title: item.title,
            kind: item.kind,
            showName: item.showName,
            season: item.season,
            episode: item.episode,
            relativePath: relativePath,
            duration: seconds.isFinite ? seconds : 0
        )
    }

    private func copyToLibrary(_ item: WorkItem) throws -> String {
        let fm = FileManager.default
        let source = item.entry.sourceURL
        let ext = source.pathExtension
        let safeBase = FileNameParser.sanitizeFilename(source.deletingPathExtension().lastPathComponent)

        var subpath: [String]
        switch item.kind {
        case .movie:
            subpath = ["Movies"]
        case .episode:
            let show = FileNameParser.sanitizeFilename(item.showName ?? "Serie")
            let seasonName = String(format: "Stagione %d", item.season ?? 1)
            subpath = ["Shows", show, seasonName]
        }

        let destDir = subpath.reduce(LibraryStorage.mediaDirectory) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var destURL = destDir.appending(path: "\(safeBase).\(ext)")
        var n = 1
        while fm.fileExists(atPath: destURL.path) {
            destURL = destDir.appending(path: "\(safeBase) (\(n)).\(ext)")
            n += 1
        }
        try fm.copyItem(at: source, to: destURL)

        let fullPath = destURL.path
        let basePath = LibraryStorage.mediaDirectory.path
        if fullPath.hasPrefix(basePath) {
            return String(fullPath.dropFirst(basePath.count + 1))
        }
        return destURL.lastPathComponent
    }
}
