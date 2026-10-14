//
//  PictureInPictureSession.swift
//  Curfs
//
//  Picture-in-Picture su iPhone (su Mac lo dà già AVPlayerView). Vive fuori
//  da PlayerView perché il video deve sopravvivere alla chiusura della
//  schermata del player:
//  - dal tasto PiP: parte la finestrella e il player a schermo intero si
//    chiude, così si può girare per l'app; "ripristina" lo riapre dalla
//    radice (`restoring`) con lo stesso PlayerViewModel, senza ripartire;
//  - uscendo dall'app mentre il video va: parte da solo (serve
//    UIBackgroundModes = audio, in Curfs-iOS-Info.plist) e rientrando si
//    richiude, il player è ancora lì.
//  Un solo AVPlayerLayer per tutta l'app (`containerView`): il controller PiP
//  è legato a quel layer, ogni nuovo player ci si aggancia.
//

#if os(iOS)
import AVKit
import SwiftUI

extension PlayerViewModel: Identifiable {}

@MainActor
@Observable
final class PictureInPictureSession: NSObject {
    static let shared = PictureInPictureSession()

    private(set) var isActive = false
    private(set) var isPossible = false
    /// Player da ripresentare a schermo intero dopo "ripristina".
    var restoring: PlayerViewModel?
    /// Cambia quando il PiP è partito dal tasto: il player aperto si chiude.
    private(set) var dismissToken = 0

    @ObservationIgnored let containerView: PlayerLayerContainerView = {
        let view = PlayerLayerContainerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }()
    @ObservationIgnored private(set) var activeVM: PlayerViewModel?
    @ObservationIgnored private weak var presentedVM: PlayerViewModel?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var restoreCompletion: ((Bool) -> Void)?
    @ObservationIgnored private var startedFromButton = false

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Un player è a schermo intero: aggancia il suo AVPlayer al layer. Se in
    /// PiP c'era un altro video, quello si chiude (salvando i progressi).
    func attach(_ vm: PlayerViewModel) {
        if let active = activeVM, active !== vm {
            activeVM = nil
            restoreCompletion?(false)
            restoreCompletion = nil
            controller?.stopPictureInPicture()
            active.stop()
        }
        presentedVM = vm
        if containerView.playerLayer.player !== vm.player {
            containerView.playerLayer.player = vm.player
        }
        ensureController()
        if vm === activeVM, let completion = restoreCompletion {
            restoreCompletion = nil
            completion(true)
        }
    }

    /// Il player a schermo intero si chiude: `true` se il video deve andare
    /// avanti nella finestrella invece di fermarsi.
    func detach(_ vm: PlayerViewModel) -> Bool {
        if presentedVM === vm { presentedVM = nil }
        return isActive && activeVM === vm
    }

    func isShowing(_ vm: PlayerViewModel) -> Bool { isActive && activeVM === vm }

    func start() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        startedFromButton = true
        controller.startPictureInPicture()
    }

    /// Rientrando nell'app col player ancora aperto, il video torna lì.
    func stopIfPlayerIsOpen() {
        guard isActive, let active = activeVM, active === presentedVM else { return }
        controller?.stopPictureInPicture()
    }

    private func ensureController() {
        guard controller == nil, isSupported,
              let controller = AVPictureInPictureController(playerLayer: containerView.playerLayer) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        self.controller = controller
    }
}

extension PictureInPictureSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = true
            activeVM = presentedVM
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            if startedFromButton { dismissToken += 1 }
            startedFromButton = false
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            isActive = false
            activeVM = nil
            startedFromButton = false
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let active = activeVM else { return completionHandler(false) }
            if active === presentedVM { return completionHandler(true) }
            // Il player è stato chiuso: lo riapre la radice, `attach` chiama
            // il completion appena è di nuovo a schermo.
            restoreCompletion = completionHandler
            restoring = active
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = false
            // Chiuso con la X senza riaprire il player: fine della visione.
            if let active = activeVM, active !== presentedVM { active.stop() }
            activeVM = nil
            restoreCompletion?(false)
            restoreCompletion = nil
        }
    }
}
#endif
