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
import AVFoundation

struct MacPlayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let library: [MediaItem]
    @State private var vm: PlayerViewModel
    /// Curfs AI in una colonna a destra: su Mac c'è spazio, il video va avanti.
    @State private var companion: CompanionChat?
    @State private var companionOpen = false

    init(item: MediaItem, library: [MediaItem]) {
        self.library = library
        _vm = State(initialValue: PlayerViewModel(item: item, library: library))
    }

    /// Riapertura dalla finestra mobile: stesso player, già avviato.
    init(resuming vm: PlayerViewModel) {
        self.library = vm.library
        _vm = State(initialValue: vm)
    }

    var body: some View {
        HStack(spacing: 0) {
            playerArea
            if companionOpen, let companion {
                CompanionChatView(chat: companion, onClose: { toggleCompanion() })
                    .frame(width: 360)
                    .background(AppBackground())
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Chiudi") { dismiss() }
            }
            if CompanionChat.isOffered {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        toggleCompanion()
                    } label: {
                        Label {
                            Text(verbatim: "Curfs AI")
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    }
                    .help(Text(verbatim: "Curfs AI (⌘K)"))
                    .keyboardShortcut("k", modifiers: .command)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    MacMiniPlayer.shared.open(vm)
                    dismiss()
                } label: {
                    Label("Finestra mobile", systemImage: "pip.enter")
                }
                .help("Finestra mobile")
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private var playerArea: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MacVideoPlayerView(
                player: vm.player,
                onSkip: { vm.skip(by: $0) },
                onRateChange: { vm.setPlaybackRate($0) }
            )
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
                isPlaying: vm.isPlaying || vm.didFinish,
                onPlayNow: { if let next = vm.nextEpisode { playNext(next) } },
                onDismiss: { vm.dismissNextEpisodePrompt() }
            )
            .opacity(vm.showNextEpisodePrompt ? 1 : 0)
            .scaleEffect(vm.showNextEpisodePrompt ? 1 : 0.9)
            .allowsHitTesting(vm.showNextEpisodePrompt)
        }
        .onAppear {
            vm.attach(modelContext: modelContext)
            MacMiniPlayer.shared.playerOpened(vm)
            vm.start()
        }
        .onDisappear {
            // Passato alla finestra mobile: il video va avanti lì.
            if !MacMiniPlayer.shared.isShowing(vm) { vm.stop() }
        }
        .onChange(of: vm.didFinish) { _, finished in
            guard finished else { return }
            if vm.nextEpisode == nil { dismiss() }
        }
    }

    private func toggleCompanion() {
        if !companionOpen, companion?.target.id != vm.item.id {
            let chat = CompanionChat(
                target: CompanionTarget(item: vm.item, position: vm.currentTime),
                asset: vm.player.currentItem?.asset, subtitleTrack: vm.selectedSubtitleTrack
            )
            chat.currentPosition = { [vm] in vm.currentTime }
            companion = chat
        }
        withAnimation(.easeInOut(duration: 0.25)) { companionOpen.toggle() }
    }

    private func playNext(_ next: MediaItem) {
        // Episodio nuovo, chat nuova (se il pannello è aperto resta aperto).
        if companionOpen {
            let chat = CompanionChat(target: CompanionTarget(item: next, position: 0))
            companion = chat
        } else {
            companion = nil
        }
        vm.stop(resetOrientation: false)
        let newVM = PlayerViewModel(item: next, library: library)
        newVM.attach(modelContext: modelContext)
        vm = newVM
        companion?.currentPosition = { [newVM] in newVM.currentTime }
        vm.start()
    }
}
