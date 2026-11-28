//
//  LibraryHomeView.swift
//  Curfs
//
//  Home: Continua a guardare e i Contenuti recenti (2026-11-28, al posto
//  delle griglie Serie TV / Film): quello che si è guardato di recente o si
//  ha sul dispositivo, con il simbolino scaricato/streaming. Una serie apre
//  la stessa scheda della Libreria del server, un film parte subito. La
//  Libreria intera si tira fuori dalla pila di dispositivi sul bordo destro
//  (ServerLibraryDrawer). In alto: profilo, impostazioni del server, import.
//  Ciò che non c'è più sul server e non è scaricato non compare.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.dateAdded, order: .reverse) private var allItems: [MediaItem]

    @State private var importVM = ImportViewModel()
    @State private var showImporter = false
    @State private var playingItem: MediaItem?
    @State private var pendingDeleteMovie: MediaItem?
    @State private var pendingDeleteShow: ShowSummary?
    @State private var showLegal = false
    @State private var showCompanionPicker = false
    @State private var companionTarget: CompanionTarget?
    @State private var showSettings = false
    @State private var availability = ServerAvailability.shared
    @State private var drawer = ServerLibraryDrawer.shared
    @State private var downloadManager = RemoteDownloadManager.shared
    @State private var profiles = ProfileSync.shared

    private var recents: [RecentTitle] {
        RecentTitle.build(from: allItems, isAvailable: availability.isAvailable)
    }

    /// Solo l'ultimo contenuto, e solo se è a metà: ha senso continuare da
    /// dove si era rimasti l'ultima volta. Se l'ultimo episodio è finito il
    /// prossimo lo trova la scheda della serie (conosce il catalogo).
    private func continueWatchingItem(in recents: [RecentTitle]) -> MediaItem? {
        guard let first = recents.first, let resume = first.resume, !resume.isNext,
              resume.item.hasProgress else { return nil }
        return resume.item
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                let recents = recents
                if recents.isEmpty {
                    emptyState
                } else {
                    content(recents)
                }

                if downloadManager.hasActiveDownloads {
                    DownloadsOverlay(manager: downloadManager)
                        .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                }

                if importVM.isImporting {
                    ImportProgressOverlay(
                        completed: importVM.progressCompleted,
                        total: importVM.progressTotal,
                        currentName: importVM.currentFileName
                    )
                    .animation(.easeInOut(duration: 0.25), value: importVM.isImporting)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: downloadManager.hasActiveDownloads)
            .navigationTitle("Libreria")
            .cleanWindowToolbar()
            #if os(iOS) && !EXTRA_POSTERS
            // Una sola scheda: niente barra in basso.
            .toolbar(.hidden, for: .tabBar)
            #endif
            // La pila della Libreria solo qui, sulla radice della home.
            .onAppear { drawer.handleVisible = true }
            // La Libreria si prepara in anticipo (invisibile): catalogo e
            // locandine caricati prima che la si tiri, sennò arrivavano a
            // metà animazione e la facevano scattare.
            #if os(iOS)
            .task {
                try? await Task.sleep(for: .seconds(1.5))
                drawer.mount()
            }
            #endif
            .onDisappear { drawer.handleVisible = false }
            .task(id: allItems.count) { await availability.refresh(allItems) }
            .onChange(of: profiles.lastSync) { _, _ in
                Task { await availability.refresh(allItems, force: true) }
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLegal = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Privacy, licenza e contatti")
                }
                #endif
                // Curfs AI in un gruppo a sé (spaziatore fisso): accanto ad
                // avatar e + macOS 26 non si decideva su come raggrupparli e
                // ricostruiva la barra di continuo (icone che sparivano, si
                // fondevano, foto del profilo ricaricata). `isOffered` è
                // fisso e il tasto c'è sempre, solo disattivato a libreria vuota.
                if CompanionChat.isOffered {
                    ToolbarItem(placement: .primaryAction) {
                        CompanionToolbarButton { showCompanionPicker = true }
                            .disabled(allItems.isEmpty)
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    ProfileToolbarButton()
                }
                // Impostazioni del server (prima l'ingranaggio stava in Cerca).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Impostazioni del server")
                    .help("Impostazioni del server")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.folder, .audiovisualContent],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importVM.handlePicked(urls: urls, modelContext: modelContext)
                case .failure(let error):
                    importVM.lastError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showLegal) {
                LegalSheet()
            }
            .sheet(isPresented: $showSettings) {
                RemoteSourceSettingsView()
            }
            .sheet(isPresented: $showCompanionPicker) {
                CompanionPickerView(items: allItems)
            }
            .sheet(item: $companionTarget) { target in
                CompanionScreen(target: target)
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 620)
                    #endif
            }
            .alert("Importazione", isPresented: Binding(
                get: { importVM.lastError != nil },
                set: { if !$0 { importVM.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importVM.lastError ?? "")
            }
            #if os(iOS)
            .fullScreenCover(item: $playingItem) { item in
                PlayerView(item: item, library: allItems)
            }
            #else
            .sheet(item: $playingItem) { item in
                MacPlayerView(item: item, library: allItems)
            }
            #endif
            .confirmationDialog(
                "Eliminare \"\(pendingDeleteMovie?.title ?? "")\"?",
                isPresented: Binding(get: { pendingDeleteMovie != nil }, set: { if !$0 { pendingDeleteMovie = nil } }),
                titleVisibility: .visible
            ) {
                Button("Elimina", role: .destructive) {
                    if let movie = pendingDeleteMovie {
                        LibraryMaintenance.delete(movie, modelContext: modelContext)
                    }
                    pendingDeleteMovie = nil
                }
                Button("Annulla", role: .cancel) { pendingDeleteMovie = nil }
            } message: {
                Text("Il file video verrà rimosso definitivamente dall'app.")
            }
            .confirmationDialog(
                "Togliere \"\(pendingDeleteShow?.name ?? "")\" dai recenti?",
                isPresented: Binding(get: { pendingDeleteShow != nil }, set: { if !$0 { pendingDeleteShow = nil } }),
                titleVisibility: .visible
            ) {
                Button("Togli", role: .destructive) {
                    if let show = pendingDeleteShow {
                        LibraryMaintenance.deleteShow(show, modelContext: modelContext)
                    }
                    pendingDeleteShow = nil
                }
                Button("Annulla", role: .cancel) { pendingDeleteShow = nil }
            } message: {
                Text("Gli episodi scaricati vengono cancellati dall'app; la serie resta nella libreria del server.")
            }
        }
    }

    private func content(_ recents: [RecentTitle]) -> some View {
        GeometryReader { geo in
            let columns = CardGrid.columns(forWidth: geo.size.width - 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let item = continueWatchingItem(in: recents) {
                        section("Continua a guardare") {
                            Button { playingItem = item } label: {
                                ContinueWatchingCard(item: item)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }

                    section("Contenuti recenti") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(recents) { title in
                                recentCard(title)
                            }
                        }
                    }

                    #if os(macOS)
                    // Su iPhone si apre solo tirando la pila a destra.
                    openLibraryButton
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                // Spazio per la linguetta della Libreria sul bordo destro.
                .padding(.trailing, 14)
                .padding(.bottom, downloadManager.hasActiveDownloads ? 70 : 0)
            }
            .safeAreaPadding(.horizontal, 16)
        }
        .animation(.easeInOut(duration: 0.3), value: recents.map(\.id))
    }

    @ViewBuilder
    private func recentCard(_ title: RecentTitle) -> some View {
        if let movie = title.movie {
            Button { playingItem = movie } label: {
                RecentTitleCard(title: title)
            }
            .buttonStyle(PressableButtonStyle())
            // Tap = guarda (in streaming se non è scaricato); tenendo premuto
            // si scarica o si toglie.
            .contextMenu { movieMenu(movie) }
        } else {
            NavigationLink {
                // La stessa scheda della Libreria del server.
                SeriesDetailView(showName: title.name)
            } label: {
                RecentTitleCard(title: title)
            }
            .buttonStyle(PressableButtonStyle())
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeleteShow = ShowSummary(name: title.name, episodes: allItems.filter { $0.kind == .episode && $0.showName == title.name })
                } label: {
                    Label("Togli dai recenti", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func movieMenu(_ movie: MediaItem) -> some View {
        if CompanionChat.isOffered {
            Button {
                companionTarget = CompanionTarget(item: movie)
            } label: {
                Label {
                    Text("Chiedi a Curfs AI")
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
        }
        if movie.isRemote {
            if RemoteDownloadManager.shared.movieDownload(title: movie.title)?.state.isActive == true {
                Label("Download in corso", systemImage: "arrow.down.circle.dotted")
            } else {
                Button("Scarica per l'offline", systemImage: "arrow.down.circle") {
                    RemoteTitleActions.download(movie)
                }
            }
        }
        Button(role: .destructive) {
            pendingDeleteMovie = movie
        } label: {
            Label(movie.isRemote ? String(localized: "Togli dai recenti") : String(localized: "Elimina film"), systemImage: "trash")
        }
    }

    /// In fondo ai recenti, per chi non ha ancora scoperto la pila a destra.
    private var openLibraryButton: some View {
        Button {
            drawer.open()
        } label: {
            Label("Tutta la libreria", systemImage: "square.stack.3d.up.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
            content()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ancora niente di recente")
                .font(.title3.weight(.semibold))
            Text("Qui trovi quello che guardi e quello che scarichi. Tira la pila a destra per aprire tutta la libreria, oppure importa video dai tuoi file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            #if os(macOS)
            Button {
                drawer.open()
            } label: {
                Label("Apri la libreria", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .padding(.top, 6)
            #endif

            Button {
                showImporter = true
            } label: {
                Label("Importa video", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
        .padding()
    }
}

#Preview {
    LibraryHomeView()
        .modelContainer(for: MediaItem.self, inMemory: true)
}
