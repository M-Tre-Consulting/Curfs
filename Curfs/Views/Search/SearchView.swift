//
//  SearchView.swift
//  Curfs
//
//  Tab "Cerca": all'apertura mostra già tutto il catalogo della fonte remota
//  configurata (il server del Raspberry Pi via Tailscale); scrivendo nella
//  barra si filtra per nome. Dalla scheda di un titolo si riproduce in
//  streaming, si aggiunge alla libreria come voce streaming, o si scarica.
//  Finché non è stato inserito un indirizzo valido nelle impostazioni (icona
//  ingranaggio) ogni richiesta fallisce in modo esplicito.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var query = ""
    @State private var results: [RemoteTitle] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedTitle: RemoteTitle?
    @State private var searchTask: Task<Void, Never>?
    @State private var downloadManager = RemoteDownloadManager.shared
    @State private var showSettings = false
    @State private var provider: RemoteContentProvider = RemoteContentProviderRegistry.makeProvider()
    @State private var didInitialLoad = false


    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppBackground()
                content

                if downloadManager.hasActiveDownloads {
                    DownloadsOverlay(manager: downloadManager)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: downloadManager.hasActiveDownloads)
            .navigationTitle("Cerca")
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filtra per titolo")
            #else
            .searchable(text: $query, prompt: "Filtra per titolo")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17))
                    }
                }
            }
            .task {
                guard !didInitialLoad else { return }
                didInitialLoad = true
                runSearch(for: "", debounce: false)
            }
            .onChange(of: query) { _, newValue in
                runSearch(for: newValue, debounce: true)
            }
            .sheet(isPresented: $showSettings) {
                RemoteSourceSettingsView()
            }
            .sheet(item: $selectedTitle) { title in
                RemoteTitleDetailView(title: title, provider: provider, downloadManager: downloadManager, modelContext: modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSourceConfigChanged)) { _ in
                provider = RemoteContentProviderRegistry.makeProvider()
                results = []
                searchError = nil
                runSearch(for: query, debounce: false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            statusState(systemImage: "exclamationmark.triangle", message: searchError)
        } else if results.isEmpty {
            if !RemoteSourceStore.current.isConfigured {
                unconfiguredPrompt
            } else if trimmedQuery.isEmpty {
                statusState(systemImage: "folder", message: "Nessun contenuto trovato sul server.")
            } else {
                statusState(systemImage: "questionmark.folder", message: "Nessun risultato per \"\(query)\"")
            }
        } else {
            resultsGrid
        }
    }

    // GeometryReader esterno invece di misurare la griglia con
    // `.onGeometryChange` e farla dipendere dal proprio risultato (vedi
    // CardGrid/LibraryHomeView per il perché). Il margine orizzontale è UNO
    // SOLO via `.safeAreaPadding` sulla ScrollView, non un `.padding()` sulla
    // griglia: con un padding applicato lì il margine sinistro spariva
    // (verificato con dati veri e righelli di debug — card e titoli a filo
    // bordo), tornava con un unico `.safeAreaPadding` in cima.
    private var resultsGrid: some View {
        GeometryReader { geo in
            let columns = CardGrid.columns(forWidth: geo.size.width - 32)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(results) { title in
                        Button {
                            selectedTitle = title
                        } label: {
                            SearchResultCard(title: title)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
                .padding(.bottom, downloadManager.hasActiveDownloads ? 70 : 0)
            }
            .safeAreaPadding(.horizontal, 16)
            .refreshable {
                provider = RemoteContentProviderRegistry.makeProvider()
                await performSearch(for: trimmedQuery)
            }
        }
    }

    private var unconfiguredPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nessuna fonte impostata")
                .font(.title3.weight(.semibold))
            Text("Imposta l'indirizzo del tuo server con l'ingranaggio qui in alto per vedere e guardare in streaming i tuoi contenuti.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showSettings = true
            } label: {
                Label("Imposta fonte", systemImage: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .padding(.top, 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusState(systemImage: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Avvia una ricerca. Con query vuota carica tutto il catalogo. Il
    /// debounce serve solo mentre si digita.
    private func runSearch(for text: String, debounce: Bool) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard RemoteSourceStore.current.isConfigured else {
            results = []
            searchError = nil
            isSearching = false
            return
        }

        searchTask = Task {
            if debounce && !trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await performSearch(for: trimmed)
        }
    }

    private func performSearch(for trimmed: String) async {
        isSearching = true
        searchError = nil
        do {
            let found = try await provider.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }
}

#Preview {
    SearchView()
        .modelContainer(for: MediaItem.self, inMemory: true)
        .preferredColorScheme(.dark)
}
