//
//  LibraryHomeView.swift
//  Curfs
//
//  Home della libreria: continua a guardare, serie TV, film. Da qui si
//  importano nuovi video tramite il picker di Files.
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

    private var shows: [ShowSummary] { ShowSummary.groups(from: allItems) }
    private var movies: [MediaItem] {
        let all = allItems.filter { $0.kind == .movie }
        // Se un film è sia scaricato sia aggiunto come voce streaming, mostra
        // solo quello locale.
        let localTitles = Set(all.filter { !$0.isRemote }.map { $0.title.lowercased() })
        return all.filter { !$0.isRemote || !localTitles.contains($0.title.lowercased()) }
    }
    /// Solo l'ultimo video in corso, non tutti quelli lasciati a metà: ha
    /// senso continuare solo da dove si era rimasti l'ultima volta.
    private var continueWatchingItem: MediaItem? {
        allItems
            .filter { $0.hasProgress }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if allItems.isEmpty {
                    emptyState
                } else {
                    content
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
            .navigationTitle("Libreria")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            .alert("Importazione", isPresented: Binding(
                get: { importVM.lastError != nil },
                set: { if !$0 { importVM.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importVM.lastError ?? "")
            }
            .fullScreenCover(item: $playingItem) { item in
                PlayerView(item: item, library: allItems)
            }
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
                "Eliminare \"\(pendingDeleteShow?.name ?? "")\" e tutti i suoi episodi?",
                isPresented: Binding(get: { pendingDeleteShow != nil }, set: { if !$0 { pendingDeleteShow = nil } }),
                titleVisibility: .visible
            ) {
                Button("Elimina tutto", role: .destructive) {
                    if let show = pendingDeleteShow {
                        LibraryMaintenance.deleteShow(show, modelContext: modelContext)
                    }
                    pendingDeleteShow = nil
                }
                Button("Annulla", role: .cancel) { pendingDeleteShow = nil }
            } message: {
                Text("Tutti gli episodi importati per questa serie verranno rimossi definitivamente.")
            }
        }
    }

    private var content: some View {
        GeometryReader { geo in
            let columns = CardGrid.columns(forWidth: geo.size.width - 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let item = continueWatchingItem {
                        section("Continua a guardare") {
                            Button { playingItem = item } label: {
                                ContinueWatchingCard(item: item)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }

                    if !shows.isEmpty {
                        section("Serie TV") {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(shows) { show in
                                    NavigationLink {
                                        ShowDetailView(show: show)
                                    } label: {
                                        ShowCardView(show: show)
                                    }
                                    .buttonStyle(PressableButtonStyle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            pendingDeleteShow = show
                                        } label: {
                                            Label("Elimina serie", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !movies.isEmpty {
                        section("Film") {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(movies) { movie in
                                    Button { playingItem = movie } label: {
                                        MovieCardView(item: movie)
                                    }
                                    .buttonStyle(PressableButtonStyle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            pendingDeleteMovie = movie
                                        } label: {
                                            Label("Elimina film", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .safeAreaPadding(.horizontal, 16)
        }
        .animation(.easeInOut(duration: 0.3), value: allItems.count)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
            content()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nessun video importato")
                .font(.title3.weight(.semibold))
            Text("Importa film o intere stagioni dai Files del tuo iPhone.\nRiconosco automaticamente le stagioni dai nomi delle cartelle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showImporter = true
            } label: {
                Label("Importa video", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .padding(.top, 6)
        }
        .padding()
    }
}

#Preview {
    LibraryHomeView()
        .modelContainer(for: MediaItem.self, inMemory: true)
}
