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
        currentShow.seasons.count > 4 ? "S\(season)" : String(localized: "Stagione \(season)")
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
        .task(id: "\(currentShow.id)-\(selectedSeason)") {
            prioritizeIntroDetection()
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
                    Text(s.withIntro == s.total ? String(localized: "Salta intro pronto") : String(localized: "Salta intro pronto per \(s.withIntro)/\(s.total)"))
                } else {
                    Image(systemName: "info.circle")
                    Text("Nessuna sigla riconosciuta per questa stagione")
                }

                Spacer()

                // Tasto manuale: cancella la cache di sigla/coda SOLO degli
                // episodi di questa stagione e li rianalizza per primi. Le
                // altre stagioni/serie restano com'erano.
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Porta in testa alla coda di analisi "salta intro" (vedi
    /// `IntroAnalysisQueue`) gli episodi della stagione mostrata, quello da
    /// riprendere per primo. Solo un cambio di ORDINE: l'analisi vera gira
    /// nella coda dell'app, quindi uscire o cambiare stagione non la
    /// interrompe (prima la cancellava a metà e l'episodio restava "senza
    /// sigla" in cache).
    private func prioritizeIntroDetection() {
        var ordered: [MediaItem] = []
        if let next = currentShow.nextToWatch,
           (next.seasonNumber ?? 1) == selectedSeason {
            ordered.append(next)
        }
        ordered.append(contentsOf: episodesForSelectedSeason)
        IntroAnalysisQueue.shared.prioritize(ordered)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            posterBanner

            if let next = currentShow.nextToWatch {
                Button {
                    playingItem = next
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(next.isFinished ? String(localized: "Rivedi") : (next.hasProgress ? String(localized: "Riprendi \(next.episodeCode ?? "")") : String(localized: "Guarda \(next.episodeCode ?? "")")))
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

    /// Una serie che viene dal catalogo remoto (in streaming o già scaricata
    /// per intero: vedi `ShowSummary.hasRemoteOrigin`) usa la locandina
    /// ufficiale, come in Cerca, PER SEMPRE — non solo finché resta in
    /// streaming. Una serie mai passata dal remoto usa invece il frame reale
    /// come sempre.
    @ViewBuilder
    private var posterBanner: some View {
        if currentShow.hasRemoteOrigin {
            RemotePosterImage(name: currentShow.name, kind: .series, systemFallback: "tv")
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
        } else if let poster = currentShow.posterItem {
            ThumbnailImageView(item: poster, systemFallback: "tv")
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
        }
    }
}
