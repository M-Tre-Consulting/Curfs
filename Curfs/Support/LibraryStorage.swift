//
//  LibraryStorage.swift
//  Curfs
//
//  Percorsi su disco usati dall'app: i video importati vengono copiati
//  dentro il container dell'app (Documents/Library) così restano
//  disponibili offline senza dover mantenere l'accesso "security scoped"
//  ai file originali selezionati nell'app Files.
//

import Foundation

nonisolated enum LibraryStorage {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var mediaDirectory: URL {
        let url = documentsDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// NON in `.cachesDirectory`: Apple documenta esplicitamente che il
    /// sistema può svuotare Caches in qualunque momento (poco spazio,
    /// aggiornamenti di iOS) — è esattamente quello che è successo con
    /// l'aggiornamento a iOS 26.1.2, lasciando le card degli episodi scaricati
    /// grigie. I video restano al sicuro in `mediaDirectory` (Documents), ma
    /// le miniature vanno in un posto che il sistema non tocca di sua
    /// iniziativa. `ThumbnailImageView` inoltre si rigenera da sola se il
    /// file manca (vedi lì), quindi anche in un caso analogo futuro il
    /// recupero è automatico invece che una card grigia permanente.
    static var thumbnailsDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Impronte percettive (hash dei fotogrammi) usate per riconoscere sigla
    /// e titoli di coda confrontando episodi tra loro: vedi FingerprintExtractor.
    static var fingerprintsDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Fingerprints", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Spazio occupato in byte da tutta la libreria video importata.
    static func libraryDiskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
