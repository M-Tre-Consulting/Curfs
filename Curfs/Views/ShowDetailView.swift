//
//  ShowDetailView.swift
//  Curfs
//
//  Pagina di una serie: selettore stagione (se ce n'è più di una) ed elenco
//  episodi con la lineetta del progresso, con timing giusto ripreso da dove
//  si era arrivati.
//

import SwiftUI
import SwiftData

struct ShowDetailView: View {
    let show: ShowSummary

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [MediaItem]
    @State private var selectedSeason: Int
    @State private var playingItem: MediaItem?
    @State private var pendingDeleteEpisode: MediaItem?
    @State private var pendingDeleteSeason: Int?

    init(show: ShowSummary) {
        self.show = show
        _selectedSeason = State(initialValue: show.seasons.first ?? 1)
    }

    private var currentShow: ShowSummary {
        ShowSummary.groups(from: allItems).first { $0.name == show.name } ?? show
    }

    private var episodesForSelectedSeason: [MediaItem] {
        currentShow.sortedEpisodes.filter { ($0.seasonNumber ?? 1) == selectedSeason }
    }

    /// Con poche stagioni c'è spazio per l'etichetta estesa; con molte, il
    /// controllo segmentato stringe ogni segmento finché "Stagione N" tronca
    /// in "Stag…" — passiamo alla forma compatta "SN" prima che succeda.
    private func seasonLabel(_ season: Int) -> String {
        currentShow.seasons.count > 4 ? "S\(season)" : "Stagione \(season)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if currentShow.seasons.count > 1 {
                    Picker("Stagione", selection: $selectedSeason) {
                        ForEach(currentShow.seasons, id: \.self) { season in
                            Text(seasonLabel(season)).tag(season)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                introAnalysisIndicator

                LazyVStack(spacing: 14) {
                    ForEach(episodesForSelectedSeason) { episode in
                        Button {
                            playingItem = episode
                        } label: {
                            EpisodeRowView(item: episode)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeleteEpisode = episode
                            } label: {
                                Label("Elimina episodio", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Un unico margine orizzontale per tutto il contenuto via
        // `.safeAreaPadding`, non tanti `.padding(.horizontal)` sparsi sui
        // singoli elementi: con più punti separati il margine sinistro
        // spariva (card/testo a filo bordo — verificato con dati veri e
        // righelli di debug, non era un problema di griglia o di bottoni).
        .safeAreaPadding(.horizontal, 16)
        .background(AppBackground())
        .navigationTitle(show.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    pendingDeleteSeason = selectedSeason
                } label: {
                    Image(systemName: "trash")
                }
            }
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
        .task(id: "\(currentShow.id)-\(selectedSeason)-\(introCacheResetTick)") {
            await warmIntroDetection()
        }
        .confirmationDialog(
            "Eliminare questo episodio?",
            isPresented: Binding(get: { pendingDeleteEpisode != nil }, set: { if !$0 { pendingDeleteEpisode = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                if let episode = pendingDeleteEpisode {
                    LibraryMaintenance.delete(episode, modelContext: modelContext)
                }
                pendingDeleteEpisode = nil
            }
            Button("Annulla", role: .cancel) { pendingDeleteEpisode = nil }
        }
        .confirmationDialog(
            "Eliminare la Stagione \(pendingDeleteSeason ?? selectedSeason)?",
            isPresented: Binding(get: { pendingDeleteSeason != nil }, set: { if !$0 { pendingDeleteSeason = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina stagione", role: .destructive) {
                if let season = pendingDeleteSeason {
                    // Calcolato PRIMA di eliminare: currentShow è derivato da
                    // @Query, che non è detto si aggiorni in modo sincrono
                    // entro questa stessa chiusura.
                    let isLastSeason = currentShow.seasons == [season]
                    LibraryMaintenance.deleteSeason(season, of: currentShow, modelContext: modelContext)
                    if isLastSeason { dismiss() }
                }
                pendingDeleteSeason = nil
            }
            Button("Annulla", role: .cancel) { pendingDeleteSeason = nil }
        } message: {
            Text("Tutti gli episodi di questa stagione verranno rimossi definitivamente dall'app.")
        }
        .onChange(of: currentShow.seasons) { _, seasons in
            if !seasons.contains(selectedSeason) {
                selectedSeason = seasons.first ?? selectedSeason
            }
        }
    }

    @State private var introStatus = IntroAnalysisStatus.shared
    /// Incrementato dal tasto "Ricalcola": cambia l'id del `.task` di warmup
    /// più sotto, che così SwiftUI cancella e riavvia da capo contro la
    /// cache appena svuotata — nessuna gestione manuale del Task.
    @State private var introCacheResetTick = 0

    /// Indicatore: gira mentre l'app analizza la sigla degli episodi di questa
    /// stagione, spunta quando sono tutti in cache (⇒ il "salta intro"
    /// comparirà alla prima riproduzione).
    @ViewBuilder
    private var introAnalysisIndicator: some View {
        let ids = episodesForSelectedSeason.filter { !$0.isRemote }.map(\.id)
        if currentShow.episodeCount > 1, !ids.isEmpty {
            let s = introStatus.summary(for: ids)
            HStack(spacing: 7) {
                if s.ready < s.total {
                    ProgressView().controlSize(.mini)
                    Text("Analisi sigla… \(s.ready)/\(s.total)")
                } else if s.withIntro > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(s.withIntro == s.total ? "Salta intro pronto" : "Salta intro pronto per \(s.withIntro)/\(s.total)")
                } else {
                    Image(systemName: "info.circle")
                    Text("Nessuna sigla riconosciuta per questa stagione")
                }

                Spacer()

                // Tasto manuale: cancella la cache su disco di sigla/coda per
                // TUTTA la libreria e la ricalcola da zero per questa
                // stagione. Il sistema si ripara già da solo nel tempo, ma
                // un modo per forzarlo subito senza aspettare resta utile.
                Button {
                    IntroCreditsAnalyzer.resetDiskCache()
                    IntroAnalysisStatus.shared.resetAll()
                    introCacheResetTick += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ricalcola sigla/coda")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pre-calcola l'analisi "salta intro" per gli episodi della stagione che
    /// stai guardando (quello da riprendere per primo), così qualunque
    /// episodio tu faccia partire da qui il pulsante c'è già invece di
    /// rincorrere la sigla. Gira mentre guardi la lista; si annulla da sola
    /// se lasci la schermata o cambi stagione.
    private func warmIntroDetection() async {
        let library = allItems
        var ordered: [MediaItem] = []
        if let next = currentShow.nextToWatch,
           (next.seasonNumber ?? 1) == selectedSeason {
            ordered.append(next)
        }
        ordered.append(contentsOf: episodesForSelectedSeason)

        var seen = Set<UUID>()
        for episode in ordered where !episode.isRemote && seen.insert(episode.id).inserted {
            if Task.isCancelled { return }
            let siblings = PlayerViewModel.siblingEpisodes(of: episode, in: library)
            guard !siblings.isEmpty else { continue }
            switch IntroCreditsAnalyzer.cacheStatus(for: episode, siblings: siblings) {
            case .readyWithIntro:
                IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: true)
                continue
            case .readyNoIntro:
                IntroAnalysisStatus.shared.markCached(episode.id, foundIntro: false)
                continue
            case .missing:
                break
            }
            IntroAnalysisStatus.shared.begin(episode.id)
            let result = await IntroCreditsAnalyzer.shared.warm(item: episode, siblings: siblings)
            IntroAnalysisStatus.shared.finish(episode.id, foundIntro: result.introRange != nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let poster = currentShow.posterItem {
                ThumbnailImageView(item: poster, systemFallback: "tv")
                    .aspectRatio(16.0/9.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
            }

            if let next = currentShow.nextToWatch {
                Button {
                    playingItem = next
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(next.isFinished ? "Rivedi" : (next.hasProgress ? "Riprendi \(next.episodeCode ?? "")" : "Guarda \(next.episodeCode ?? "")"))
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
            }
        }
    }
}
