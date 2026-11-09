//
//  PlayerView.swift
//  Curfs
//
//  Schermata di riproduzione a schermo intero, con controlli custom fluidi
//  e avanzamento automatico all'episodio successivo per il binge watching.
//

import SwiftUI
import SwiftData
import AVFoundation

struct PlayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let library: [MediaItem]
    @State private var vm: PlayerViewModel
    @State private var pip = PictureInPictureSession.shared
    /// Curfs AI: la chat resta (non si perde chiudendo il pannello) finché
    /// si guarda lo stesso episodio.
    @State private var companion: CompanionChat?
    @State private var companionOpen = false
    @State private var resumeAfterCompanion = false

    init(item: MediaItem, library: [MediaItem]) {
        self.library = library
        _vm = State(initialValue: PlayerViewModel(item: item, library: library))
    }

    /// Riapertura dal Picture-in-Picture: stesso player, già avviato.
    init(resuming vm: PlayerViewModel) {
        self.library = vm.library
        _vm = State(initialValue: vm)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayerLayerView(player: vm.player)
                .ignoresSafeArea()

            PlayerGestureZones(vm: vm)
                .ignoresSafeArea()

            // Il pannello resta sempre montato e animiamo opacità/scala/blur
            // direttamente: il Liquid Glass (blur/rifrazione "vivi") non
            // anima bene la propria rimozione quando la view viene tolta
            // dall'albero con if/.transition (spariva di scatto), mentre
            // un'animazione di proprietà su una view già presente funziona
            // in modo affidabile in entrambe le direzioni.
            PlayerControlsOverlay(
                vm: vm,
                showsPictureInPicture: pip.isPossible,
                onPictureInPicture: { pip.start() },
                showsCompanion: CompanionChat.isOffered,
                onCompanion: openCompanion,
                onClose: { dismiss() },
                onNextEpisode: { if let next = vm.nextEpisode { playNext(next) } }
            )
            .opacity(vm.controlsVisible ? 1 : 0)
            .scaleEffect(vm.controlsVisible ? 1 : 0.94)
            .blur(radius: vm.controlsVisible ? 0 : 6)
            .allowsHitTesting(vm.controlsVisible)

            if vm.isInIntro {
                SkipIntroButton { vm.skipIntro() }
            }

            // Sempre montata, come PlayerControlsOverlay sopra: il Liquid
            // Glass non anima la propria rimozione se tolta dall'albero con
            // if/.transition (vedi commento più su), quindi qui si anima
            // solo opacità/scala invece di condizionare la presenza della
            // view a `showNextEpisodePrompt`.
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

            companionPanel
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.attach(modelContext: modelContext)
            pip.attach(vm)
            vm.start()
        }
        .onDisappear {
            // Chiuso per passare al Picture-in-Picture: il video va avanti.
            if pip.detach(vm) {
                vm.resetOrientation()
            } else {
                vm.stop()
            }
        }
        .onChange(of: pip.dismissToken) {
            if pip.isShowing(vm) { dismiss() }
        }
        .onChange(of: vm.didFinish) { _, finished in
            guard finished else { return }
            if vm.nextEpisode == nil {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Rientrando dal background, riallinea la rotazione fisica a
            // quella che il player dovrebbe avere: senza questo, se il
            // sistema avesse comunque riportato lo schermo in verticale nel
            // frattempo, il player resterebbe convinto di essere ancora in
            // orizzontale (e il tasto di rotazione richiederebbe due tocchi
            // per tornare utile, vedi PlayerViewModel.toggleOrientation).
            guard newPhase == .active else { return }
            pip.stopIfPlayerIsOpen()
            OrientationController.requestOrientation(vm.isLandscape ? .landscape : .portrait)
        }
    }

    // MARK: - Curfs AI

    /// In orizzontale una colonna a destra (il video resta visibile a
    /// sinistra), in verticale la metà bassa dello schermo. Sempre montato e
    /// animato con opacità/spostamento, come gli altri pannelli in vetro.
    @ViewBuilder
    private var companionPanel: some View {
        if let companion {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                let panel = CompanionChatView(chat: companion, onClose: closeCompanion)
                    .environment(\.colorScheme, .dark)
                    .glassEffect(.regular.tint(Color.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                Group {
                    if landscape {
                        panel
                            .frame(width: min(420, geo.size.width * 0.46))
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, 8)
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(x: companionOpen ? 0 : 60)
                    } else {
                        panel
                            .frame(height: geo.size.height * 0.6)
                            .padding(.horizontal, 8)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .offset(y: companionOpen ? 0 : 80)
                    }
                }
                .opacity(companionOpen ? 1 : 0)
                .allowsHitTesting(companionOpen)
            }
        }
    }

    private func openCompanion() {
        if companion?.target.id != vm.item.id {
            let target = CompanionTarget(item: vm.item, position: vm.currentTime)
            let chat = CompanionChat(target: target, asset: vm.player.currentItem?.asset, subtitleTrack: vm.selectedSubtitleTrack)
            chat.currentPosition = { [vm] in vm.currentTime }
            companion = chat
        }
        // Si mette in pausa per non perdersi niente mentre si scrive.
        resumeAfterCompanion = vm.isPlaying
        vm.pause()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            vm.controlsVisible = false
            companionOpen = true
        }
    }

    private func closeCompanion() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { companionOpen = false }
        if resumeAfterCompanion { vm.play() }
        resumeAfterCompanion = false
    }

    private func playNext(_ next: MediaItem) {
        companionOpen = false
        companion = nil
        let wasLandscape = vm.isLandscape
        vm.stop(resetOrientation: false)
        let newVM = PlayerViewModel(item: next, library: library)
        newVM.attach(modelContext: modelContext)
        newVM.isLandscape = wasLandscape
        pip.attach(newVM)
        vm = newVM
        vm.start()
    }
}
