//
//  RemoteTitleActions.swift
//  Curfs
//
//  Azioni sui titoli del server condivise da Cerca, dalla Libreria e dalla
//  scheda serie: riprodurre un film in streaming (riusando l'item già in
//  libreria se c'è, così i progressi continuano), aggiungerlo, scaricarlo.
//  Più `PosterEditor`, il cambio copertina (Foto / File / Ripristina) che
//  prima viveva dentro la vecchia scheda di Cerca.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

@MainActor
enum RemoteTitleActions {
    static func episodeTitle(_ episode: RemoteEpisode) -> String {
        if let title = episode.title, !title.isEmpty { return title }
        return String(localized: "Episodio \(episode.number)")
    }

    /// Film già in libreria con lo stesso nome, preferendo quello scaricato.
    static func libraryMovie(named name: String, in library: [MediaItem]) -> MediaItem? {
        let movies = library.filter { $0.kind == .movie && $0.title.caseInsensitiveCompare(name) == .orderedSame }
        return movies.first { !$0.isRemote } ?? movies.first
    }

    /// Cosa riprodurre toccando un film in Cerca: il file scaricato se c'è,
    /// poi la voce streaming già in libreria (stesso URL o stesso nome), se no
    /// una voce nuova che si salva da sola al primo avanzamento reale.
    static func playableMovie(_ title: RemoteTitle, provider: RemoteContentProvider,
                              library: [MediaItem]) async throws -> MediaItem {
        if let local = library.first(where: { $0.kind == .movie && !$0.isRemote && $0.title.caseInsensitiveCompare(title.name) == .orderedSame }) {
            return local
        }
        let url = try await provider.streamTarget(for: title, episode: nil).url
        if let existing = library.first(where: { $0.remoteURLString == url.absoluteString }) {
            return existing
        }
        return MediaItem(title: title.name, kind: .movie, relativePath: "", remoteURLString: url.absoluteString)
    }

    static func addMovieToLibrary(_ title: RemoteTitle, provider: RemoteContentProvider,
                                  library: [MediaItem], modelContext: ModelContext) async throws {
        guard libraryMovie(named: title.name, in: library) == nil else { return }
        let url = try await provider.streamTarget(for: title, episode: nil).url
        modelContext.insert(MediaItem(title: title.name, kind: .movie, relativePath: "", remoteURLString: url.absoluteString))
        try? modelContext.save()
    }

    static func downloadMovie(_ title: RemoteTitle, provider: RemoteContentProvider) async throws {
        let target = try await provider.resolveDownload(for: title, episode: nil)
        RemoteDownloadManager.shared.start(
            target: target,
            request: RemoteDownloadRequest(title: title.name, kind: .movie, showName: nil, season: nil, episode: nil)
        )
    }

    /// Scarica per l'offline un item in streaming già in libreria: il file da
    /// scaricare è lo stesso URL che usa il player.
    static func download(_ item: MediaItem) {
        guard let string = item.remoteURLString, let url = URL(string: string) else { return }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        RemoteDownloadManager.shared.start(
            target: RemoteDownloadTarget(fileURL: url, suggestedFileExtension: ext),
            request: RemoteDownloadRequest(
                title: item.title, kind: item.kind, showName: item.showName,
                season: item.seasonNumber, episode: item.episodeNumber
            )
        )
    }
}

/// Nome della serie in libreria che corrisponde a un titolo del server,
/// tollerando le differenze di formattazione (`il-trono-di-spade` vs
/// `Il Trono di Spade`) e i nomi contenuti uno nell'altro.
enum ShowNameMatcher {
    static func bestMatch(for name: String, in candidates: [String]) -> String? {
        if let exact = candidates.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let target = normalized(name)
        guard target.count >= 3 else { return nil }
        if let same = candidates.first(where: { normalized($0) == target }) {
            return same
        }
        return candidates.first {
            let n = normalized($0)
            guard n.count >= 5 else { return false }
            return target.contains(n) || n.contains(target)
        }
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

// MARK: - Cambio copertina

/// Copertina scelta dall'utente: ritagliata a 2:3 e salvata sul server
/// accanto al contenuto (vedi `RemoteContentProvider.setCustomPoster`).
/// I selettori (Foto / File) si agganciano con `.posterEditorPickers(_:)`.
@MainActor
@Observable
final class PosterEditor {
    var isWorking = false
    var error: String?
    var showFileImporter = false
    #if os(iOS)
    var showPhotoPicker = false
    var photoItem: PhotosPickerItem?
    #endif

    /// Titolo a cui va la prossima immagine scelta.
    private(set) var target: RemoteTitle?
    /// Ultima copertina caricata/ripristinata per titolo (id): la scheda la
    /// mostra subito, senza aspettare che il catalogo venga riletto.
    private(set) var changed: [String: (url: URL?, custom: Bool)] = [:]

    func posterURL(for title: RemoteTitle) -> URL? { changed[title.id].map(\.url) ?? title.posterURL }
    func isCustom(_ title: RemoteTitle) -> Bool { changed[title.id]?.custom ?? title.hasCustomPoster }

    // Le aperture sono rimandate al giro dopo: chiamate da un menu (anche
    // contestuale) su Mac, cambiare subito lo stato che lo ridisegna può
    // lasciare l'NSMenu bloccato (vedi CLAUDE.md, "Salva in:").
    func pickFile(for title: RemoteTitle) {
        target = title
        Task { @MainActor in self.showFileImporter = true }
    }

    #if os(iOS)
    func pickPhoto(for title: RemoteTitle) {
        target = title
        Task { @MainActor in self.showPhotoPicker = true }
    }
    #endif

    func restore(_ title: RemoteTitle) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let url = try await RemoteContentProviderRegistry.shared.removeCustomPoster(for: title)
                changed[title.id] = (url, false)
                error = nil
                NotificationCenter.default.post(name: .remotePosterChanged, object: nil)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    fileprivate func upload(_ data: Data) async {
        guard let title = target else { return }
        isWorking = true
        defer { isWorking = false }
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            PosterImageProcessing.posterJPEG(from: data)
        }).value else {
            error = String(localized: "Questo file non sembra un'immagine valida.")
            return
        }
        do {
            let url = try await RemoteContentProviderRegistry.shared.setCustomPoster(jpeg, for: title)
            changed[title.id] = (url, true)
            error = nil
            NotificationCenter.default.post(name: .remotePosterChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    fileprivate func fileChosen(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data else {
            error = String(localized: "Impossibile leggere il file scelto.")
            return
        }
        Task { await upload(data) }
    }

    #if os(iOS)
    fileprivate func photoChosen() {
        guard let item = photoItem else { return }
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                error = String(localized: "Impossibile leggere la foto scelta.")
                return
            }
            await upload(data)
        }
    }
    #endif
}

private struct PosterEditorPickers: ViewModifier {
    @Bindable var editor: PosterEditor

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $editor.showFileImporter, allowedContentTypes: [.image]) { result in
                editor.fileChosen(result)
            }
            #if os(iOS)
            .photosPicker(isPresented: $editor.showPhotoPicker, selection: $editor.photoItem, matching: .images)
            .onChange(of: editor.photoItem) { _, _ in editor.photoChosen() }
            #endif
    }
}

extension View {
    func posterEditorPickers(_ editor: PosterEditor) -> some View {
        modifier(PosterEditorPickers(editor: editor))
    }
}

/// Voci "copertina" da mettere in un menu (contestuale o no) per un titolo
/// del server che supporta copertine proprie.
struct PosterMenuItems: View {
    let title: RemoteTitle
    let editor: PosterEditor

    var body: some View {
        if title.customPosterUploadURL != nil {
            #if os(iOS)
            Button("Copertina da Foto", systemImage: "photo.on.rectangle") { editor.pickPhoto(for: title) }
            Button("Copertina da File", systemImage: "folder") { editor.pickFile(for: title) }
            #else
            Button("Cambia copertina…", systemImage: "photo.badge.plus") { editor.pickFile(for: title) }
            #endif
            if editor.isCustom(title) {
                Button("Ripristina copertina automatica", systemImage: "arrow.uturn.backward") { editor.restore(title) }
            }
        }
    }
}
