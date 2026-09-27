//
//  MacVideoPlayerView.swift
//  CurfsMac
//
//  Wrapper attorno a AVPlayerView (AVKit nativo di macOS): a differenza del
//  player custom su iPhone (VideoPlayerLayerView + controlli Liquid Glass
//  disegnati a mano), qui ci appoggiamo ai controlli nativi del Mac —
//  scrubber, volume, toggle schermo intero e soprattutto Picture-in-Picture
//  flottante e ridimensionabile "gratis", senza doverlo ricostruire a mano.
//
//  Skip ±10s con A/D: equivalente da tastiera del doppio-tap di
//  PlayerGestureZones su iOS (file iOS-only, escluso dal target Mac). Un
//  NSEvent local monitor invece di SwiftUI .onKeyPress perché AVPlayerView è
//  un NSView nativo che può diventare first responder per i suoi controlli
//  (spazio, frecce): con .onKeyPress sull'albero SwiftUI l'evento rischia di
//  non arrivare mai se il focus è sull'AVPlayerView. Il monitor intercetta i
//  tasti prima della responder chain, indipendentemente da chi ha il focus.
//
//  Auto-hide di controlli+cursore durante inattività: quello nativo di
//  AVPlayerView(.floating) non si è innescato in pratica in questo contesto
//  (SwiftUI NSViewRepresentable), né in finestra né in fullscreen — invece di
//  continuare a inseguire il meccanismo interno non documentato, lo
//  implementiamo a mano nel Coordinator con un timer di inattività:
//  qualunque movimento mouse/click/tasto rimostra controlli+cursore e
//  riparte il timer; allo scadere (solo se sta riproducendo, mai in pausa)
//  si passa a controlsStyle = .none e si nasconde il cursore.
//  `window.acceptsMouseMovedEvents` va abilitato esplicitamente: senza, il
//  window server non genera affatto eventi .mouseMoved per la finestra e il
//  monitor sotto non riceverebbe mai nulla.
//  - Transizione animata: `controlsStyle` va assegnato tramite il proxy
//    `.animator()` dentro `NSAnimationContext.runAnimationGroup` per ottenere
//    un vero cross-fade invece del cambio a scatto — è così che AVPlayerView
//    si aspetta che questa proprietà venga animata (assegnarla "nuda" la
//    cambia istantaneamente, ed è anche la causa più probabile del blur
//    vetroso del pannello controlli rimasto "a metà" invece di sparire).
//  - Mentre un menu di AVPlayerView è aperto (es. velocità di riproduzione,
//    tracce audio/sottotitoli) il timer di inattività va sospeso: altrimenti
//    i controlli sparivano sotto al menu aperto se l'utente si fermava a
//    leggere le opzioni per più di idleDelay. `NSMenu.didBeginTracking/
//    didEndTrackingNotification` sono notifiche di sistema per QUALSIASI
//    menu (incluso quello interno di AVPlayerView, che non possediamo e non
//    possiamo agganciare direttamente).
//  - `onRateChange`: la velocità di riproduzione scelta dal menu nativo di
//    AVPlayerView cambia `player.rate` direttamente, scavalcando
//    `PlayerViewModel.setPlaybackRate` (che su Mac non ha alcuna UI propria,
//    a differenza dell'overlay custom iOS) — senza agganciarla qui non
//    verrebbe mai salvata in UserDefaults, e in più il prossimo play()/pause()
//    la resetterebbe silenziosamente a `vm.playbackRate` (1x di default).
//    Osservando `player.rate` via KVO e rilanciandolo dentro
//    `setPlaybackRate` la persistenza torna identica a quella iOS.

import SwiftUI
import AVKit
import AppKit

struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let onSkip: (Double) -> Void
    let onRateChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, onSkip: onSkip, onRateChange: onRateChange)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        context.coordinator.playerView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        context.coordinator.onSkip = onSkip
        context.coordinator.onRateChange = onRateChange
        if let window = nsView.window, !window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = true
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onSkip: (Double) -> Void
        var onRateChange: (Double) -> Void
        weak var playerView: AVPlayerView?

        private let player: AVPlayer
        private var keyMonitor: Any?
        private var activityMonitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var menuBeginObserver: NSObjectProtocol?
        private var menuEndObserver: NSObjectProtocol?
        private var rateObservation: NSKeyValueObservation?
        private var hideWorkItem: DispatchWorkItem?
        private var cursorHidden = false
        private var isMenuTracking = false
        private static let idleDelay: TimeInterval = 2.5
        private static let fadeDuration: TimeInterval = 0.2

        init(player: AVPlayer, onSkip: @escaping (Double) -> Void, onRateChange: @escaping (Double) -> Void) {
            self.player = player
            self.onSkip = onSkip
            self.onRateChange = onRateChange
        }

        func startMonitoring() {
            guard keyMonitor == nil else { return }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                    return event
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "a":
                    self.onSkip(-10)
                    self.showControls()
                    return nil
                case "d":
                    self.onSkip(10)
                    self.showControls()
                    return nil
                default:
                    self.showControls()
                    return event
                }
            }

            activityMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
            ) { [weak self] event in
                self?.showControls()
                return event
            }

            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.unhideCursorIfNeeded()
            }

            menuBeginObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isMenuTracking = true
                self.showControls()
            }

            menuEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isMenuTracking = false
                self.showControls()
            }

            rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if player.rate > 0 {
                        self.onRateChange(Double(player.rate))
                    }
                    self.showControls()
                }
            }

            showControls()
        }

        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
            if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
            keyMonitor = nil
            activityMonitor = nil
            resignObserver = nil
            menuBeginObserver = nil
            menuEndObserver = nil
            rateObservation = nil
            hideWorkItem?.cancel()
            hideWorkItem = nil
            unhideCursorIfNeeded()
        }

        private func showControls() {
            hideWorkItem?.cancel()
            setControlsStyle(.floating)
            unhideCursorIfNeeded()

            guard player.rate != 0, !isMenuTracking else { return }
            let work = DispatchWorkItem { [weak self] in self?.hideControls() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
        }

        private func hideControls() {
            guard player.rate != 0, !isMenuTracking else { return }
            setControlsStyle(.none)
            hideCursorIfNeeded()
        }

        private func setControlsStyle(_ style: AVPlayerViewControlsStyle) {
            guard let playerView, playerView.controlsStyle != style else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                playerView.animator().controlsStyle = style
            }
        }

        private func hideCursorIfNeeded() {
            guard !cursorHidden else { return }
            cursorHidden = true
            NSCursor.hide()
        }

        private func unhideCursorIfNeeded() {
            guard cursorHidden else { return }
            cursorHidden = false
            NSCursor.unhide()
        }
    }
}
