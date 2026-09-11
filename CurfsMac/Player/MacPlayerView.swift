//
//  MacPlayerView.swift
//  CurfsMac
//
//  Equivalente di PlayerView (iOS) per Mac: stessa PlayerViewModel condivisa
//  (progresso, salta-intro, prossimo episodio), ma i controlli di
//  riproduzione sono quelli nativi di AVKit invece del player custom Liquid
//  Glass — vedi MacVideoPlayerView. Niente rotazione/orientamento: su Mac la
//  finestra è semplicemente ridimensionabile.
//

import SwiftUI
import SwiftData

struct MacPlayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let library: [MediaItem]
    @State private var vm: PlayerViewModel

    init(item: MediaItem, library: [MediaItem]) {
        self.library = library
        _vm = State(initialValue: PlayerViewModel(item: item, library: library))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MacVideoPlayerView(player: vm.player)
                .ignoresSafeArea()

            if vm.isInIntro {
                SkipIntroButton { vm.skipIntro() }
            }

            // Stessa logica di iOS: view sempre montata, si anima
            // opacità/scala invece di essere tolta dall'albero (il Liquid
            // Glass non anima bene la propria rimozione).
            NextEpisodePromptView(
                next: vm.nextEpisode,
                isPresented: vm.showNextEpisodePrompt,
                onPlayNow: { if let next = vm.nextEpisode { playNext(next) } },
                onDismiss: { vm.dismissNextEpisodePrompt() }
            )
            .opacity(vm.showNextEpisodePrompt ? 1 : 0)
            .scaleEffect(vm.showNextEpisodePrompt ? 1 : 0.9)
            .allowsHitTesting(vm.showNextEpisodePrompt)
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Chiudi") { dismiss() }
            }
        }
        .onAppear {
            vm.attach(modelContext: modelContext)
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
        .onChange(of: vm.didFinish) { _, finished in
            guard finished else { return }
            if vm.nextEpisode == nil { dismiss() }
        }
    }

    private func playNext(_ next: MediaItem) {
        vm.stop(resetOrientation: false)
        let newVM = PlayerViewModel(item: next, library: library)
        newVM.attach(modelContext: modelContext)
        vm = newVM
        vm.start()
    }
}
