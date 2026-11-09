//
//  CompanionPickerView.swift
//  Curfs
//
//  Dal tasto Curfs AI della libreria: si sceglie di cosa parlare tra quello
//  che c'è nel profilo (dove si era rimasti, una serie → episodio, un film) e
//  si apre la chat. Dalla scheda serie si parte direttamente dagli episodi.
//

import SwiftUI

struct CompanionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [MediaItem]
    /// Dalla scheda serie: si parte dagli episodi di questa.
    var showName: String?

    private enum Route: Hashable {
        case show(String)
        case chat(UUID)
    }

    @State private var path: [Route] = []

    private var shows: [ShowSummary] { ShowSummary.groups(from: items) }
    private var movies: [MediaItem] {
        let all = items.filter { $0.kind == .movie }
        let localTitles = Set(all.filter { !$0.isRemote }.map { $0.title.lowercased() })
        return all.filter { !$0.isRemote || !localTitles.contains($0.title.lowercased()) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var lastWatched: MediaItem? {
        items.filter { $0.lastPlayedAt != nil }.max { $0.lastPlayedAt! < $1.lastPlayedAt! }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let showName {
                    episodeList(showName)
                } else {
                    rootList
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .show(let name): episodeList(name)
                case .chat(let id):
                    if let item = items.first(where: { $0.id == id }) {
                        CompanionScreen(target: CompanionTarget(item: item))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    // MARK: - Tutto il profilo

    private var rootList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    CompanionIcon(size: 40)
                    Text("Scegli cosa stai guardando: ti spiego personaggi e scene senza spoiler.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            if let last = lastWatched {
                Section("Dove eri rimasto") {
                    NavigationLink(value: Route.chat(last.id)) { row(last, title: last.showName ?? last.title) }
                }
            }
            if !shows.isEmpty {
                Section("Serie TV") {
                    ForEach(shows) { show in
                        NavigationLink(value: Route.show(show.name)) {
                            HStack(spacing: 12) {
                                thumbnail(show.posterItem)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: show.name).font(.body.weight(.semibold))
                                    Text("\(show.episodeCount) episodi")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !movies.isEmpty {
                Section("Film") {
                    ForEach(movies) { movie in
                        NavigationLink(value: Route.chat(movie.id)) { row(movie, title: movie.title) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(Text(verbatim: "Curfs AI"))
        .toolbar { closeButton }
    }

    // MARK: - Episodi di una serie

    private func episodeList(_ name: String) -> some View {
        let show = shows.first { $0.name == name }
        let episodes = show?.sortedEpisodes ?? []
        let seasons = Array(Set(episodes.map { $0.seasonNumber ?? 1 })).sorted()
        return List {
            if let next = show?.nextToWatch {
                Section("Dove sei arrivato") {
                    NavigationLink(value: Route.chat(next.id)) { episodeRow(next) }
                }
            }
            ForEach(seasons, id: \.self) { season in
                Section("Stagione \(season)") {
                    ForEach(episodes.filter { ($0.seasonNumber ?? 1) == season }) { episode in
                        NavigationLink(value: Route.chat(episode.id)) { episodeRow(episode) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(Text(verbatim: name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { if showName != nil { closeButton } }
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        HStack(spacing: 12) {
            thumbnail(episode)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: episode.subtitle ?? episode.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                progressText(episode)
            }
        }
    }

    private func row(_ item: MediaItem, title: String) -> some View {
        HStack(spacing: 12) {
            thumbnail(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body.weight(.semibold)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                progressText(item)
            }
        }
    }

    @ViewBuilder
    private func progressText(_ item: MediaItem) -> some View {
        Group {
            if item.isFinished {
                Label("Visto", systemImage: "checkmark.circle.fill")
            } else if item.playbackPosition > 30 {
                Label("Sei a \(TimeFormatter.format(item.playbackPosition))", systemImage: "play.circle")
            } else {
                Label("Non iniziato", systemImage: "circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func thumbnail(_ item: MediaItem?) -> some View {
        Group {
            if let item {
                ThumbnailImageView(item: item)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 72, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ToolbarContentBuilder
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Chiudi") { dismiss() }
        }
    }
}

/// Il tasto Curfs AI delle barre in alto (libreria, scheda serie).
struct CompanionToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(verbatim: "Curfs AI")
            } icon: {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.accentColor, Color(red: 0.85, green: 0.35, blue: 0.75))
            }
        }
        .help(Text(verbatim: "Curfs AI"))
    }
}
