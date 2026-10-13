//
//  SeriesDetailView.swift
//  Curfs
//
//  Scheda unica di una serie, la stessa da Cerca e dalla Libreria: unisce
//  gli episodi in libreria (scaricati o in streaming) con quelli presenti sul
//  server. Ogni episodio si tocca per guardarlo (il file scaricato se c'è,
//  altrimenti in streaming) e ha il suo tasto download con il progresso;
//  in alto Riprendi, Aggiungi alla libreria, Scarica stagione e lo stato del
//  "salta sigla". Prima erano due schede diverse (Cerca: streaming/aggiungi
//  senza progressi; Libreria: progressi senza download).
//

import SwiftUI
import SwiftData

struct SeriesDetailView: View {
    /// Titolo del server, se arriviamo da Cerca. Dalla Libreria si cerca da
    /// solo nel catalogo per nome (best-effort, vedi `ShowNameMatcher`).
    private let initialRemoteTitle: RemoteTitle?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [MediaItem]

    /// Nome della serie in libreria (= dove finiscono aggiunte e download).
    @State private var showName: String
    @State private var remoteTitle: RemoteTitle?
    @State private var seasons: [RemoteSeason] = []
    @State private var streamURLs: [String: URL] = [:]
    @State private var isLoadingCatalog = false
    @State private var catalogError: String?
    @State private var selectedSeason: Int?

    @State private var isPreparingPlayback = false
    @State private var playback: PlaybackRequest?
    /// Voci streaming create per riprodurre episodi non ancora in libreria:
    /// riusate finché la scheda è aperta (si salvano da sole al primo
    /// avanzamento reale, vedi `PlayerViewModel.persistProgress`).
    @State private var transientItems: [String: MediaItem] = [:]

    @State private var pendingDelete: MediaItem?
    @State private var pendingDeleteSeason: Int?
    @State private var posterEditor = PosterEditor()
    @State private var introStatus = IntroAnalysisStatus.shared
    private let downloads = RemoteDownloadManager.shared

    /// Dalla Libreria.
    init(showName: String) {
        self.initialRemoteTitle = nil
        _showName = State(initialValue: showName)
    }

    /// Da Cerca: `showName` è la serie già in libreria che corrisponde al
    /// titolo (se c'è), altrimenti il nome del server.
    init(remoteTitle: RemoteTitle, showName: String?) {
        self.initialRemoteTitle = remoteTitle
        _remoteTitle = State(initialValue: remoteTitle)
        _showName = State(initialValue: showName ?? remoteTitle.name)
    }

    private struct PlaybackRequest: Identifiable {
        let id = UUID()
        let item: MediaItem
        let library: [MediaItem]
    }

    /// Un episodio, comunque sia disponibile: scaricato, in streaming in
    /// libreria, solo sul server, o più cose insieme.
    struct Entry: Identifiable {
        let id: String
        let season: Int
        let number: Int?
        var title: String
        var local: MediaItem?
        var stream: MediaItem?
        var remote: RemoteEpisode?
        var remoteURL: URL?

        /// L'item con i progressi da mostrare/riprendere.
        var item: MediaItem? { local ?? stream }
        var code: String {
            guard let number else { return String(localized: "Stagione \(season)") }
            return String(format: "S%02dE%02d", season, number)
        }
    }

    // MARK: - Dati

    private var libraryEpisodes: [MediaItem] {
        allItems.filter { $0.kind == .episode && $0.showName == showName }
    }

    private static func key(_ season: Int, _ episode: Int) -> String { "\(season)|\(episode)" }

    private var entries: [Entry] {
        var byKey: [String: Entry] = [:]
        for season in seasons {
            for ep in season.episodes {
                let k = Self.key(season.number, ep.number)
                byKey[k] = Entry(id: k, season: season.number, number: ep.number,
                                 title: RemoteTitleActions.episodeTitle(ep), remote: ep, remoteURL: streamURLs[k])
            }
        }
        for item in libraryEpisodes {
            let season = item.seasonNumber ?? 1
            let k = item.episodeNumber.map { Self.key(season, $0) } ?? item.id.uuidString
            var entry = byKey[k] ?? Entry(id: k, season: season, number: item.episodeNumber, title: item.title)
            if item.isRemote {
                if entry.stream == nil || (item.lastPlayedAt ?? .distantPast) > (entry.stream?.lastPlayedAt ?? .distantPast) {
                    entry.stream = item
                }
            } else {
                entry.local = item
                entry.title = item.title
            }
            byKey[k] = entry
        }
        return byKey.values.sorted {
            ($0.season, $0.number ?? .max, $0.title) < ($1.season, $1.number ?? .max, $1.title)
        }
    }

    private var allSeasons: [Int] { Array(Set(entries.map(\.season))).sorted() }

    private var currentSeason: Int {
        if let selectedSeason, allSeasons.contains(selectedSeason) { return selectedSeason }
        return nextToWatch?.season ?? allSeasons.first ?? 1
    }

    private var seasonEntries: [Entry] { entries.filter { $0.season == currentSeason } }

    /// Come `ShowSummary.nextToWatch`: l'ultimo episodio lasciato a metà,
    /// altrimenti il primo non finito, altrimenti l'ultimo.
    private var nextToWatch: Entry? {
        let all = entries
        let inProgress = all.filter { $0.item?.hasProgress == true }
            .max { ($0.item?.lastPlayedAt ?? .distantPast) < ($1.item?.lastPlayedAt ?? .distantPast) }
        return inProgress ?? all.first { $0.item?.isFinished != true } ?? all.last
    }

    private var hasRemoteOrigin: Bool { remoteTitle != nil || libraryEpisodes.contains(where: \.isRemoteOrigin) }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                if let catalogError, hasRemoteOrigin {
                    Label(catalogError, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                episodesSection
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Un solo margine orizzontale per tutto il contenuto (vedi CLAUDE.md).
        .safeAreaPadding(.horizontal, 16)
        .background(AppBackground())
        .navigationTitle(showName)
        .cleanWindowToolbar()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if seasonEntries.contains(where: { $0.item != nil }) {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        pendingDeleteSeason = currentSeason
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Rimuovi stagione dalla libreria")
                }
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
        .posterEditorPickers(posterEditor)
        #if os(iOS)
        .fullScreenCover(item: $playback) { request in
            PlayerView(item: request.item, library: request.library)
        }
        #else
        .sheet(item: $playback) { request in
            MacPlayerView(item: request.item, library: request.library)
        }
        #endif
        .task { await loadCatalog() }
        .task(id: "\(showName)-\(currentSeason)-\(seasonEntries.count)") {
            prioritizeIntroDetection()
        }
        .confirmationDialog(
            deleteTitle(for: pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Rimuovi", role: .destructive) {
                if let item = pendingDelete { LibraryMaintenance.delete(item, modelContext: modelContext) }
                pendingDelete = nil
            }
            Button("Annulla", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(
            "Rimuovere la Stagione \(pendingDeleteSeason ?? currentSeason) dalla libreria?",
            isPresented: Binding(get: { pendingDeleteSeason != nil }, set: { if !$0 { pendingDeleteSeason = nil } }),
            titleVisibility: .visible
        ) {
            Button("Rimuovi stagione", role: .destructive) {
                if let season = pendingDeleteSeason { deleteSeason(season) }
                pendingDeleteSeason = nil
            }
            Button("Annulla", role: .cancel) { pendingDeleteSeason = nil }
        } message: {
            Text("Gli episodi scaricati vengono cancellati dall'app; quelli sul server restano guardabili in streaming.")
        }
    }

    private func deleteTitle(for item: MediaItem?) -> String {
        guard let item else { return "" }
        return item.isRemote
            ? String(localized: "Togliere questo episodio dalla libreria?")
            : String(localized: "Eliminare il download di questo episodio?")
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            posterArt
            VStack(alignment: .leading, spacing: 6) {
                Text(showName)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                statusBadge
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            // Locandina sfocata come fondale della card.
            posterImage
                .blur(radius: 40)
                .opacity(0.55)
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        .padding(.top, 8)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let remoteTitle {
            RemoteImage(url: posterEditor.posterURL(for: remoteTitle)) { posterPlaceholder }
        } else if hasRemoteOrigin {
            RemotePosterImage(name: showName, kind: .series, systemFallback: "tv")
        } else if let item = entries.first(where: { $0.local != nil })?.local {
            ThumbnailImageView(item: item, systemFallback: "tv")
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "tv")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
    }

    /// Locandina 2:3 per le serie del server, frame 16:9 per quelle
    /// importate da File (non hanno una locandina, vedi `ShowCardView`).
    private var posterArt: some View {
        let isPoster = hasRemoteOrigin
        return GeometryReader { proxy in
            posterImage
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .frame(width: isPoster ? 116 : 150, height: isPoster ? 174 : 84)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .overlay {
            if posterEditor.isWorking {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.4))
                    ProgressView()
                }
            }
        }
        .overlay(alignment: .bottomTrailing) { posterEditButton }
        .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 8)
    }

    @ViewBuilder
    private var posterEditButton: some View {
        if let remoteTitle, remoteTitle.customPosterUploadURL != nil {
            #if os(iOS)
            Menu {
                PosterMenuItems(title: remoteTitle, editor: posterEditor)
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .glassEffect(in: Circle())
            .padding(6)
            .disabled(posterEditor.isWorking)
            .accessibilityLabel("Cambia copertina")
            #else
            // Niente `Menu` su Mac (vedi CLAUDE.md, NSMenu bloccato): file
            // diretto; il ripristino è nel menu contestuale di Cerca.
            Button {
                posterEditor.pickFile(for: remoteTitle)
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(in: Circle())
            .padding(6)
            .disabled(posterEditor.isWorking)
            .help("Cambia copertina…")
            #endif
        }
    }

    private var metaLine: String {
        let seasonsText = String(localized: "\(allSeasons.count) stagioni")
        let episodesText = String(localized: "\(entries.count) episodi")
        return "\(seasonsText) · \(episodesText)"
    }

    @ViewBuilder
    private var statusBadge: some View {
        let downloaded = entries.filter { $0.local != nil }.count
        let total = entries.count
        if total > 0 {
            let (icon, text): (String, String) = {
                if downloaded == total { return ("arrow.down.circle.fill", String(localized: "Scaricata")) }
                if downloaded > 0 { return ("arrow.down.circle", String(localized: "Scaricati \(downloaded) di \(total)")) }
                if libraryEpisodes.isEmpty { return ("icloud", String(localized: "Sul server")) }
                return ("dot.radiowaves.left.and.right", String(localized: "In streaming"))
            }()
            Label(text, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(in: Capsule())
        }
        if let saveMenu = saveTargetMenu { saveMenu }
    }

    // MARK: - Azioni

    private var actions: some View {
        VStack(spacing: 10) {
            if let next = nextToWatch {
                Button {
                    play(next)
                } label: {
                    Label(playLabel(for: next), systemImage: "play.fill")
                        .lineLimit(1)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .disabled(isPreparingPlayback)
            }

            if remoteTitle != nil || seasonEntries.contains(where: { $0.remoteURL != nil || $0.stream != nil }) {
                HStack(spacing: 10) {
                    libraryButton
                    seasonDownloadButton
                }
            }

            introAnalysisIndicator
        }
    }

    private func playLabel(for entry: Entry) -> String {
        guard let item = entry.item else { return String(localized: "Guarda \(entry.code)") }
        if item.isFinished { return String(localized: "Rivedi \(entry.code)") }
        if item.hasProgress { return String(localized: "Riprendi \(entry.code)") }
        return String(localized: "Guarda \(entry.code)")
    }

    private var missingFromLibrary: [Entry] {
        entries.filter { $0.item == nil && $0.remoteURL != nil }
    }

    private var libraryButton: some View {
        let missing = missingFromLibrary.count
        let inLibrary = !libraryEpisodes.isEmpty
        let text: String = !inLibrary ? String(localized: "Aggiungi")
            : (missing > 0 ? String(localized: "Aggiungi altri \(missing)") : String(localized: "In libreria"))
        return Button {
            addAllToLibrary()
        } label: {
            Label(text, systemImage: inLibrary && missing == 0 ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .disabled(missing == 0)
    }

    /// In una vista a parte: è l'unica cosa (con il tasto della singola
    /// riga) che deve ridisegnarsi a ogni avanzamento dei download, non
    /// l'intera scheda — sennò lo scorrimento scatta finché si scarica.
    private var seasonDownloadButton: some View {
        SeasonDownloadButton(show: showName, entries: seasonEntries) { download($0) }
    }

    /// Serie di destinazione per aggiunte e download, solo arrivando da Cerca
    /// quando in libreria ci sono altre serie: il nome sul server spesso non
    /// coincide con quello della serie già importata.
    private var saveTargetMenu: AnyView? {
        guard let remoteTitle = initialRemoteTitle else { return nil }
        let names = Set(allItems.filter { $0.kind == .episode }.compactMap(\.showName))
            .subtracting([remoteTitle.name])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        return AnyView(
            Menu {
                Button {
                    // Rimandata al giro dopo: cambiare in modo sincrono lo
                    // stato che ridisegna questo Menu lo lascia bloccato
                    // aperto su macOS (vedi CLAUDE.md).
                    Task { @MainActor in showName = remoteTitle.name }
                } label: {
                    if showName == remoteTitle.name {
                        Label("\(remoteTitle.name) (nuova serie)", systemImage: "checkmark")
                    } else {
                        Text("\(remoteTitle.name) (nuova serie)")
                    }
                }
                ForEach(names, id: \.self) { name in
                    Button {
                        Task { @MainActor in showName = name }
                    } label: {
                        if showName == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Salva in: \(showName)").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        )
    }

    /// Stato del "salta sigla" per gli episodi scaricati della stagione
    /// (l'analisi confronta fotogrammi: non si fa in streaming).
    @ViewBuilder
    private var introAnalysisIndicator: some View {
        let ids = seasonEntries.compactMap(\.local).map(\.id)
        if entries.filter({ $0.local != nil }).count > 1, !ids.isEmpty {
            let s = introStatus.summary(for: ids)
            HStack(spacing: 7) {
                if s.ready < s.total {
                    ProgressView().controlSize(.mini)
                    Text("Analisi sigla… \(s.ready)/\(s.total)")
                } else if s.withIntro > 0 {
                    Image(systemName: "forward.end.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(s.withIntro == s.total ? String(localized: "Salta intro pronto") : String(localized: "Salta intro pronto per \(s.withIntro)/\(s.total)"))
                } else {
                    Image(systemName: "info.circle")
                    Text("Nessuna sigla riconosciuta per questa stagione")
                }

                Spacer()

                // Cancella la cache di sigla/coda SOLO degli episodi di
                // questa stagione e li rianalizza per primi.
                Button {
                    Task { await IntroAnalysisQueue.shared.recompute(ids) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ricalcola sigla/coda")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if !seasonEntries.isEmpty, seasonEntries.allSatisfy({ $0.local == nil }), remoteTitle != nil || hasRemoteOrigin {
            Label("Scarica almeno due episodi per attivare il salta sigla", systemImage: "forward.end")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Episodi

    @ViewBuilder
    private var episodesSection: some View {
        if entries.isEmpty {
            if isLoadingCatalog {
                ProgressView().padding().frame(maxWidth: .infinity)
            } else {
                Text("Nessun episodio trovato.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                seasonSelector
                LazyVStack(spacing: 12) {
                    ForEach(seasonEntries) { entry in
                        episodeRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var seasonSelector: some View {
        if allSeasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(allSeasons, id: \.self) { season in
                        let selected = season == currentSeason
                        Button {
                            withAnimation(.snappy) { selectedSeason = season }
                        } label: {
                            Text("Stagione \(season)")
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background {
                                    if selected { Capsule().fill(Color.accentColor) }
                                }
                                .glassEffect(in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        } else {
            Text("Stagione \(currentSeason) · \(String(localized: "\(seasonEntries.count) episodi"))")
                .font(.headline)
        }
    }

    private func episodeRow(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Button {
                play(entry)
            } label: {
                SeriesEpisodeRow(entry: entry)
            }
            .buttonStyle(.plain)
            .disabled(isPreparingPlayback || (entry.item == nil && entry.remoteURL == nil))

            DownloadControl(show: showName, entry: entry) { download(entry) }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if Self.hasDownloadSource(entry) {
                Button("Scarica per l'offline", systemImage: "arrow.down.circle") { download(entry) }
            }
            if let local = entry.local {
                Button(role: .destructive) { pendingDelete = local } label: {
                    Label("Elimina download", systemImage: "trash")
                }
            } else if let stream = entry.stream {
                Button(role: .destructive) { pendingDelete = stream } label: {
                    Label("Togli dalla libreria", systemImage: "minus.circle")
                }
            }
        }
    }

    /// Si può scaricare (a parte un eventuale download già in corso, che
    /// `download(_:)` controlla al momento del tocco).
    static func hasDownloadSource(_ entry: Entry) -> Bool {
        entry.local == nil && entry.number != nil && (entry.remoteURL != nil || entry.stream != nil)
    }

    // MARK: - Catalogo

    private func loadCatalog() async {
        guard RemoteSourceStore.current.isConfigured, seasons.isEmpty else { return }
        let provider = RemoteContentProviderRegistry.shared
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            if remoteTitle == nil {
                // Dalla Libreria: si cerca la serie nel catalogo per nome.
                let series = try await provider.search(query: "").filter { $0.kind == .series }
                guard let match = ShowNameMatcher.bestMatch(for: showName, in: series.map(\.name)),
                      let title = series.first(where: { $0.name == match }) else { return }
                remoteTitle = title
            }
            guard let remoteTitle else { return }
            let loaded = try await provider.seasons(for: remoteTitle)
            var urls: [String: URL] = [:]
            for season in loaded {
                for ep in season.episodes {
                    urls[Self.key(season.number, ep.number)] = try await provider.streamTarget(for: remoteTitle, episode: ep).url
                }
            }
            streamURLs = urls
            seasons = loaded
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: - Riproduzione

    /// L'item da dare al player: il file scaricato, poi la voce streaming in
    /// libreria, poi una voce nuova (riusata finché la scheda è aperta).
    private func playable(_ entry: Entry) -> MediaItem? {
        if let item = entry.item { return item }
        guard let url = entry.remoteURL else { return nil }
        let key = url.absoluteString
        if let existing = allItems.first(where: { $0.remoteURLString == key }) ?? transientItems[key] {
            return existing
        }
        let created = MediaItem(
            title: entry.title, kind: .episode, showName: showName,
            seasonNumber: entry.season, episodeNumber: entry.number,
            relativePath: "", remoteURLString: key
        )
        transientItems[key] = created
        return created
    }

    private func play(_ entry: Entry) {
        // Tutti gli episodi di tutte le stagioni, scaricati e non: così
        // l'episodio successivo parte anche a cavallo tra file scaricati e
        // streaming, o tra una stagione e l'altra.
        let library = entries.compactMap(playable)
        guard let target = playable(entry) else { return }
        playback = PlaybackRequest(item: target, library: library)
    }

    // MARK: - Libreria e download

    private func addAllToLibrary() {
        for entry in missingFromLibrary {
            guard let url = entry.remoteURL else { continue }
            let key = url.absoluteString
            if let transient = transientItems[key], transient.modelContext == nil {
                modelContext.insert(transient)
            } else if !allItems.contains(where: { $0.remoteURLString == key }) {
                modelContext.insert(MediaItem(
                    title: entry.title, kind: .episode, showName: showName,
                    seasonNumber: entry.season, episodeNumber: entry.number,
                    relativePath: "", remoteURLString: key
                ))
            }
        }
        try? modelContext.save()
    }

    private func download(_ entry: Entry) {
        guard Self.hasDownloadSource(entry), let number = entry.number else { return }
        if downloads.download(show: showName, season: entry.season, episode: number)?.state.isActive == true { return }
        let request = RemoteDownloadRequest(
            title: entry.title, kind: .episode, showName: showName,
            season: entry.season, episode: number
        )
        if let remoteTitle, let ep = entry.remote {
            Task {
                do {
                    let target = try await RemoteContentProviderRegistry.shared.resolveDownload(for: remoteTitle, episode: ep)
                    downloads.start(target: target, request: request)
                } catch {
                    catalogError = error.localizedDescription
                }
            }
        } else if let stream = entry.stream, let string = stream.remoteURLString, let url = URL(string: string) {
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
            downloads.start(target: RemoteDownloadTarget(fileURL: url, suggestedFileExtension: ext), request: request)
        }
    }

    private func deleteSeason(_ season: Int) {
        let items = libraryEpisodes.filter { ($0.seasonNumber ?? 1) == season }
        let leavesNothing = seasons.isEmpty && items.count == libraryEpisodes.count
        for item in items { LibraryMaintenance.delete(item, modelContext: modelContext) }
        if leavesNothing { dismiss() }
    }

    /// Porta in testa alla coda del "salta intro" gli episodi scaricati della
    /// stagione mostrata, quello da riprendere per primo. Solo un cambio di
    /// ORDINE: l'analisi gira nella coda dell'app, uscire non la interrompe
    /// (vedi `IntroAnalysisQueue`).
    private func prioritizeIntroDetection() {
        var ordered: [MediaItem] = []
        if let next = nextToWatch?.local, next.seasonNumber == currentSeason { ordered.append(next) }
        ordered.append(contentsOf: seasonEntries.compactMap(\.local))
        guard !ordered.isEmpty else { return }
        IntroAnalysisQueue.shared.prioritize(ordered)
    }
}

// MARK: - Riga episodio

private struct SeriesEpisodeRow: View {
    let entry: SeriesDetailView.Entry

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                thumbnail
                    .frame(width: 124, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if entry.item?.isFinished == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                if let item = entry.item, item.hasProgress {
                    ProgressLineView(fraction: item.progressFraction)
                        .frame(width: 124)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.code)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if entry.local == nil {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    if let item = entry.item, item.duration > 0 {
                        Text(TimeFormatter.formatCompact(item.duration))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let item = entry.item {
            ThumbnailImageView(item: item, systemFallback: "tv")
                .aspectRatio(16.0/9.0, contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Tasto download di un episodio: scarica / progresso (tocca per annullare) /
/// riprova / già scaricato.
private struct DownloadControl: View {
    let show: String
    let entry: SeriesDetailView.Entry
    let onDownload: () -> Void
    private var downloads: RemoteDownloadManager { .shared }

    private var item: RemoteDownloadItem? {
        guard entry.local == nil, let number = entry.number else { return nil }
        return downloads.download(show: show, season: entry.season, episode: number)
    }

    var body: some View {
        Group {
            if entry.local != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Scaricato")
            } else if let item {
                switch item.state {
                case .downloading(let progress):
                    Button { downloads.cancel(id: item.id) } label: { ring(progress) }
                        .accessibilityLabel("Annulla download")
                case .finalizing:
                    ProgressView().controlSize(.small)
                case .paused, .failed:
                    Button { downloads.retry(id: item.id) } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Riprendi download")
                case .completed:
                    ProgressView().controlSize(.small)
                }
            } else if SeriesDetailView.hasDownloadSource(entry) {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Scarica per l'offline")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
    }

    private func ring(_ progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
        }
        .frame(width: 22, height: 22)
    }
}

/// "Scarica stagione": scarica gli episodi della stagione non ancora
/// scaricati né in download.
private struct SeasonDownloadButton: View {
    let show: String
    let entries: [SeriesDetailView.Entry]
    let onDownload: (SeriesDetailView.Entry) -> Void
    private var downloads: RemoteDownloadManager { .shared }

    private func isDownloading(_ entry: SeriesDetailView.Entry) -> Bool {
        guard let number = entry.number else { return false }
        return downloads.download(show: show, season: entry.season, episode: number)?.state.isActive == true
    }

    var body: some View {
        let downloadable = entries.filter { SeriesDetailView.hasDownloadSource($0) && !isDownloading($0) }
        let anyActive = entries.contains { isDownloading($0) }
        let allLocal = !entries.isEmpty && entries.allSatisfy { $0.local != nil }
        let text: String
        let icon: String
        if allLocal {
            text = String(localized: "Scaricata"); icon = "checkmark"
        } else if downloadable.isEmpty && anyActive {
            text = String(localized: "In download…"); icon = "arrow.down.circle.dotted"
        } else {
            text = String(localized: "Scarica stagione"); icon = "arrow.down.to.line"
        }
        return Button {
            for entry in downloadable { onDownload(entry) }
        } label: {
            Label(text, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .disabled(downloadable.isEmpty)
    }
}
