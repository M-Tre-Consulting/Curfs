//
//  PlayerView.swift
//  Curfs
//
//  Schermata di riproduzione a schermo intero, con controlli custom fluidi
//  e avanzamento automatico all'episodio successivo per il binge watching.
//

import SwiftUI
import SwiftData

struct PlayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let library: [MediaItem]
    @State private var vm: PlayerViewModel

    init(item: MediaItem, library: [MediaItem]) {
        self.library = library
        _vm = State(initialValue: PlayerViewModel(item: item, library: library))
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
                onPlayNow: { if let next = vm.nextEpisode { playNext(next) } },
                onDismiss: { vm.dismissNextEpisodePrompt() }
            )
            .opacity(vm.showNextEpisodePrompt ? 1 : 0)
            .scaleEffect(vm.showNextEpisodePrompt ? 1 : 0.9)
            .allowsHitTesting(vm.showNextEpisodePrompt)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.attach(modelContext: modelContext)
            vm.start()
        }
        .onDisappear {
            vm.stop()
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
            OrientationController.requestOrientation(vm.isLandscape ? .landscape : .portrait)
        }
    }

    private func playNext(_ next: MediaItem) {
        let wasLandscape = vm.isLandscape
        vm.stop(resetOrientation: false)
        let newVM = PlayerViewModel(item: next, library: library)
        newVM.attach(modelContext: modelContext)
        newVM.isLandscape = wasLandscape
        vm = newVM
        vm.start()
    }
}
