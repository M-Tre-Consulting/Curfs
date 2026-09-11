//
//  RemoteTitleDetailView.swift
//  Curfs
//
//  Scheda di un risultato di ricerca remoto. Per un film: riproduci in
//  streaming oppure scarica per l'offline. Per una serie: selettore stagione
//  e lista episodi, ognuno con play (streaming) e download. Lo streaming usa
//  lo stesso URL diretto del file (AVPlayer legge il remoto con richieste
//  Range) — nessun download preventivo.
//

import SwiftUI
import SwiftData

struct RemoteTitleDetailView: View {
    let title: RemoteTitle
    let provider: RemoteContentProvider
    var downloadManager: RemoteDownloadManager
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var seasons: [RemoteSeason] = []
    @State private var selectedSeason: Int?
    @State private var isLoadingSeasons = false
    @State private var loadError: String?
    @State private var startedEpisodeIDs: Set<String> = []
    @State private var movieDownloadStarted = false

    @State private var isPreparingPlayback = false
    @State private var playback: PlaybackRequest?
    /// Item remoti già visti in passato (persistiti): li riusiamo così i
    /// progressi continuano invece di ripartire da zero.
    @State private var existingRemoteItems: [MediaItem] = []

    /// Nomi delle serie già in libreria (file scaricati): permettono di
    /// salvare una stagione dal Pi dentro una serie esistente invece di
    /// crearne una nuova.
    @State private var existingShowNames: [String] = []
    /// Episodi locali (non remoti) già in libreria: per non creare un
    /// doppione streaming di qualcosa che è già stato scaricato.
    @State private var existingLocalEpisodes: [MediaItem] = []
    /// Serie di destinazione per i salvataggi da questa scheda. `nil` = crea
    /// una serie nuova col nome remoto.
    @State private var saveTargetShow: String?
    @State private var savedToLibrary = false

    private var effectiveShowName: String { saveTargetShow ?? title.name }

    /// Cerca tra le serie già in libreria quella che corrisponde a questo
    /// titolo remoto, gestendo le differenze di formattazione del nome
    /// (`il-trono-di-spade` vs `Il Trono di Spade`) e prefissi come "Il"/"The".
    private func bestExistingShowMatch() -> String? {
        guard !existingShowNames.isEmpty else { return nil }
        if let exact = existingShowNames.first(where: { $0.caseInsensitiveCompare(title.name) == .orderedSame }) {
            return exact
        }
        let target = normalizedName(title.name)
        guard target.count >= 3 else { return nil }
        if let normalized = existingShowNames.first(where: { normalizedName($0) == target }) {
            return normalized
        }
        return existingShowNames.first(where: {
            let n = normalizedName($0)
            guard n.count >= 5 else { return false }
            return target.contains(n) || n.contains(target)
        })
    }

    private func normalizedName(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private struct PlaybackRequest: Identifiable {
        let id = UUID()
        let item: MediaItem
        let library: [MediaItem]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if title.kind == .movie {
                        movieSection
                    } else {
                        seriesSection
                    }
                }
                .padding(.bottom, 24)
            }
            .background(AppBackground())
            .navigationTitle(title.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .overlay {
                if isPreparingPlayback {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView().controlSize(.large)
                    }
                }
            }
            #if os(macOS)
            // Il "Chiudi" nella toolbar da solo non basta come via d'uscita
            // affidabile su Mac per questo pannello (presentato come sheet
            // sopra Cerca): una X sempre visibile in alto a destra, separata
            // dalla toolbar, garantisce di poter chiudere il pannello in
            // ogni caso.
            .overlay(alignment: .topTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(in: Circle())
                .padding(14)
            }
            #endif
            .task {
                let all = (try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? []
                existingRemoteItems = all.filter { $0.isRemote }
                existingLocalEpisodes = all.filter { !$0.isRemote && $0.kind == .episode }
                existingShowNames = Set(existingLocalEpisodes.compactMap(\.showName))
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                // Se questa serie esiste già in libreria, di default i
                // salvataggi ci finiscono dentro invece di crearne una nuova.
                if title.kind == .series, saveTargetShow == nil {
                    saveTargetShow = bestExistingShowMatch()
                }
                if title.kind == .series { await loadSeasons() }
            }
            #if os(iOS)
            .fullScreenCover(item: $playback) { request in
                PlayerView(item: request.item, library: request.library)
            }
            #else
            .sheet(item: $playback) { request in
                MacPlayerView(item: request.item, library: request.library)
            }
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            posterHeader

            if let overview = title.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var posterHeader: some View {
        if let url = title.posterURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
            .padding(.horizontal)
        }
    }

    // MARK: - Film

    private var movieSection: some View {
        VStack(spacing: 12) {
            Button {
                playMovie()
            } label: {
                Label("Riproduci in streaming", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .disabled(isPreparingPlayback)

            Button {
                addMovieToLibrary()
            } label: {
                Label(savedToLibrary ? "Aggiunto ai Film" : "Aggiungi ai Film",
                      systemImage: savedToLibrary ? "checkmark" : "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .disabled(savedToLibrary)

            Button {
                downloadMovie()
            } label: {
                Label(movieDownloadStarted ? "Download avviato" : "…oppure scaricalo per l'offline",
                      systemImage: movieDownloadStarted ? "checkmark" : "arrow.down.to.line")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .disabled(movieDownloadStarted)
        }
        .padding(.horizontal)
    }

    // MARK: - Serie

    @ViewBuilder
    private var seriesSection: some View {
        if isLoadingSeasons {
            ProgressView()
                .padding()
                .frame(maxWidth: .infinity)
        } else if seasons.isEmpty {
            Text(loadError == nil ? "Nessuna stagione trovata." : "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if seasons.count > 1 {
                    Picker("Stagione", selection: Binding(
                        get: { selectedSeason ?? seasons.first?.number ?? 1 },
                        set: { selectedSeason = $0 }
                    )) {
                        ForEach(seasons) { season in
                            Text(seasons.count > 4 ? "S\(season.number)" : "Stagione \(season.number)").tag(season.number)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                } else if let only = seasons.first {
                    Text("Stagione \(only.number) · \(only.episodes.count) episodi")
                        .font(.headline)
                        .padding(.horizontal)
                }

                saveToLibrarySection

                LazyVStack(spacing: 10) {
                    ForEach(currentEpisodes) { episode in
                        episodeRow(episode)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Salva l'intera stagione corrente nella libreria locale (download dal
    /// Pi), come serie nuova o dentro una serie già esistente.
    @ViewBuilder
    private var saveToLibrarySection: some View {
        VStack(spacing: 10) {
            if !existingShowNames.isEmpty {
                Menu {
                    Button {
                        // Rimandata al prossimo run loop: cambiare qui lo
                        // stesso @State che ridisegna il contenuto di questo
                        // Menu, in modo sincrono dentro l'azione di un suo
                        // Button, manda in confusione il tracking dell'NSMenu
                        // su macOS (resta aperto/bloccato) — bug noto
                        // dell'interazione SwiftUI/AppKit, non visibile su
                        // iOS dove UIKit gestisce i menu diversamente.
                        Task { @MainActor in saveTargetShow = nil }
                    } label: {
                        if saveTargetShow == nil {
                            Label("\(title.name) (nuova serie)", systemImage: "checkmark")
                        } else {
                            Text("\(title.name) (nuova serie)")
                        }
                    }
                    ForEach(existingShowNames, id: \.self) { name in
                        Button {
                            Task { @MainActor in saveTargetShow = name }
                        } label: {
                            if saveTargetShow == name {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tv")
                        Text("Salva in: \(effectiveShowName)")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                addSeasonToLibrary()
            } label: {
                Label(savedToLibrary ? "Aggiunta alla libreria" : "Aggiungi Stagione \(currentSeasonNumber) alla libreria",
                      systemImage: savedToLibrary ? "checkmark" : "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .disabled(savedToLibrary || currentEpisodes.isEmpty)

            Button {
                downloadSeason()
            } label: {
                Label(seasonFullyQueued ? "Stagione in download" : "…oppure scaricala per l'offline",
                      systemImage: seasonFullyQueued ? "checkmark" : "arrow.down.to.line")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .disabled(seasonFullyQueued || currentEpisodes.isEmpty)
        }
        .padding(.horizontal)
    }

    private var seasonFullyQueued: Bool {
        !currentEpisodes.isEmpty && currentEpisodes.allSatisfy { startedEpisodeIDs.contains($0.id) }
    }

    private var currentSeasonNumber: Int {
        selectedSeason ?? seasons.first?.number ?? 1
    }

    private var currentEpisodes: [RemoteEpisode] {
        seasons.first { $0.number == currentSeasonNumber }?.episodes ?? []
    }

    private func episodeRow(_ episode: RemoteEpisode) -> some View {
        let started = startedEpisodeIDs.contains(episode.id)
        return HStack(spacing: 12) {
            Button {
                playEpisode(episode)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Episodio %02d", episode.number))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let epTitle = episode.title, !epTitle.isEmpty {
                            Text(epTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPreparingPlayback)

            Button {
                downloadEpisode(episode)
            } label: {
                Image(systemName: started ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(started ? Color.accentColor : Color.secondary)
            }
            .disabled(started)
        }
        .padding(12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Caricamento stagioni

    private func loadSeasons() async {
        isLoadingSeasons = true
        loadError = nil
        do {
            seasons = try await provider.seasons(for: title)
            selectedSeason = seasons.first?.number
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingSeasons = false
    }

    // MARK: - Aggiungi alla libreria come voce streaming (nessun file)

    /// Inserisce in libreria gli episodi della stagione corrente come voci
    /// in streaming: nessun download, la riproduzione parte dal Pi. Salta
    /// quelli già presenti (stessa URL remota) o già scaricati in locale
    /// nella serie di destinazione.
    private func addSeasonToLibrary() {
        let season = currentSeasonNumber
        let show = effectiveShowName
        let eps = currentEpisodes
        Task {
            var inserted = 0
            for ep in eps {
                do {
                    let stream = try await provider.streamTarget(for: title, episode: ep)
                    let key = stream.url.absoluteString
                    if existingRemoteItems.contains(where: { $0.remoteURLString == key }) { continue }
                    let dupLocal = existingLocalEpisodes.contains {
                        $0.showName == show && ($0.seasonNumber ?? 1) == season && ($0.episodeNumber ?? -1) == ep.number
                    }
                    if dupLocal { continue }
                    let epTitle = (ep.title?.isEmpty == false) ? ep.title! : "Episodio \(ep.number)"
                    let mi = MediaItem(
                        title: epTitle,
                        kind: .episode,
                        showName: show,
                        seasonNumber: season,
                        episodeNumber: ep.number,
                        relativePath: "",
                        remoteURLString: key
                    )
                    modelContext.insert(mi)
                    existingRemoteItems.append(mi)
                    inserted += 1
                } catch {
                    loadError = error.localizedDescription
                }
            }
            if inserted > 0 { try? modelContext.save() }
            savedToLibrary = true
        }
    }

    private func addMovieToLibrary() {
        Task {
            do {
                let stream = try await provider.streamTarget(for: title, episode: nil)
                let key = stream.url.absoluteString
                if !existingRemoteItems.contains(where: { $0.remoteURLString == key }) {
                    let mi = MediaItem(title: title.name, kind: .movie, relativePath: "", remoteURLString: key)
                    modelContext.insert(mi)
                    existingRemoteItems.append(mi)
                    try? modelContext.save()
                }
                savedToLibrary = true
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Streaming

    private func playMovie() {
        isPreparingPlayback = true
        loadError = nil
        Task {
            defer { isPreparingPlayback = false }
            do {
                let target = try await provider.streamTarget(for: title, episode: nil)
                let item = reuseOrMake(streamURL: target.url) {
                    MediaItem(title: title.name, kind: .movie, relativePath: "",
                              remoteURLString: target.url.absoluteString)
                }
                playback = PlaybackRequest(item: item, library: [item])
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func playEpisode(_ episode: RemoteEpisode) {
        isPreparingPlayback = true
        loadError = nil
        Task {
            defer { isPreparingPlayback = false }
            do {
                // "Libreria" con tutti gli episodi di tutte le stagioni: così
                // l'auto-avanzamento funziona anche a cavallo di stagione,
                // come per la libreria locale. Con HTTPTreeProvider queste
                // risoluzioni sono lookup immediati (catalogo già in memoria).
                var library: [MediaItem] = []
                var target: MediaItem?
                for season in seasons {
                    for ep in season.episodes {
                        let stream = try await provider.streamTarget(for: title, episode: ep)
                        let epTitle = (ep.title?.isEmpty == false) ? ep.title! : "Episodio \(ep.number)"
                        let mi = reuseOrMake(streamURL: stream.url) {
                            MediaItem(
                                title: epTitle,
                                kind: .episode,
                                showName: title.name,
                                seasonNumber: season.number,
                                episodeNumber: ep.number,
                                relativePath: "",
                                remoteURLString: stream.url.absoluteString
                            )
                        }
                        library.append(mi)
                        if ep.id == episode.id { target = mi }
                    }
                }
                if let target {
                    playback = PlaybackRequest(item: target, library: library)
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func reuseOrMake(streamURL: URL, _ make: () -> MediaItem) -> MediaItem {
        let key = streamURL.absoluteString
        if let existing = existingRemoteItems.first(where: { $0.remoteURLString == key }) {
            return existing
        }
        let created = make()
        existingRemoteItems.append(created)
        return created
    }

    // MARK: - Download offline (invariato)

    private func downloadMovie() {
        movieDownloadStarted = true
        Task {
            do {
                let target = try await provider.resolveDownload(for: title, episode: nil)
                downloadManager.start(
                    target: target,
                    request: RemoteDownloadRequest(title: title.name, kind: .movie, showName: nil, season: nil, episode: nil)
                )
            } catch {
                movieDownloadStarted = false
                loadError = error.localizedDescription
            }
        }
    }

    private func downloadEpisode(_ episode: RemoteEpisode) {
        startedEpisodeIDs.insert(episode.id)
        let seasonNumber = currentSeasonNumber
        let show = effectiveShowName
        Task {
            do {
                let target = try await provider.resolveDownload(for: title, episode: episode)
                let episodeTitle = (episode.title?.isEmpty == false) ? episode.title! : "Episodio \(episode.number)"
                downloadManager.start(
                    target: target,
                    request: RemoteDownloadRequest(
                        title: episodeTitle,
                        kind: .episode,
                        showName: show,
                        season: seasonNumber,
                        episode: episode.number
                    )
                )
            } catch {
                startedEpisodeIDs.remove(episode.id)
                loadError = error.localizedDescription
            }
        }
    }

    /// Scarica dal Pi tutti gli episodi della stagione corrente e li mette in
    /// libreria dentro `effectiveShowName` (serie nuova o esistente). I
    /// singoli download sono gestiti da RemoteDownloadManager, con progresso
    /// nel pannello in basso.
    private func downloadSeason() {
        let season = currentSeasonNumber
        let show = effectiveShowName
        let episodes = currentEpisodes.filter { !startedEpisodeIDs.contains($0.id) }
        for ep in episodes { startedEpisodeIDs.insert(ep.id) }
        Task {
            for ep in episodes {
                do {
                    let target = try await provider.resolveDownload(for: title, episode: ep)
                    let epTitle = (ep.title?.isEmpty == false) ? ep.title! : "Episodio \(ep.number)"
                    downloadManager.start(
                        target: target,
                        request: RemoteDownloadRequest(
                            title: epTitle,
                            kind: .episode,
                            showName: show,
                            season: season,
                            episode: ep.number
                        )
                    )
                } catch {
                    startedEpisodeIDs.remove(ep.id)
                    loadError = error.localizedDescription
                }
            }
        }
    }
}
