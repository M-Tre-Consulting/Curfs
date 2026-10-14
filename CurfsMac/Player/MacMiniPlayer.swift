//
//  MacMiniPlayer.swift
//  CurfsMac
//
//  Finestra mobile al posto del Picture-in-Picture di sistema, che su Mac si
//  aggancia sempre a un angolo dello schermo. Questa è un pannello sempre in
//  primo piano che resta esattamente dove lo si lascia, si ridimensiona dagli
//  angoli mantenendo le proporzioni del video e ricorda posizione e grandezza
//  (`setFrameAutosaveName`). Resta visibile su tutte le scrivanie e sopra le
//  app a schermo intero.
//
//  Stesso PlayerViewModel del player nella finestra: il video non riparte.
//  "Torna alla finestra" lo riapre nella finestra principale (`restoring`,
//  presentato da RootTabView); la X ferma la visione salvando i progressi.
//

import SwiftUI
import AppKit
import AVKit

extension PlayerViewModel: Identifiable {}

@MainActor
@Observable
final class MacMiniPlayer: NSObject, NSWindowDelegate {
    static let shared = MacMiniPlayer()

    /// Player da riaprire nella finestra principale.
    var restoring: PlayerViewModel?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private(set) var activeVM: PlayerViewModel?
    @ObservationIgnored private var keepPlayingOnClose = false

    func isShowing(_ vm: PlayerViewModel) -> Bool { activeVM === vm }

    func open(_ vm: PlayerViewModel) {
        close(stopping: true)
        activeVM = vm

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let size = Self.videoSize(of: vm)
        panel.contentAspectRatio = size
        panel.contentMinSize = NSSize(width: 240, height: 240 * size.height / size.width)
        panel.contentView = NSHostingView(rootView: MacMiniPlayerContent(
            vm: vm,
            onExpand: { [weak self] in self?.expand() },
            onClose: { [weak self] in self?.close(stopping: true) }
        ))

        // Posizione e grandezza dell'ultima volta; la prima volta in basso a
        // destra. L'altezza si riallinea alle proporzioni di questo video.
        if !panel.setFrameUsingName(Self.frameName) {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setContentSize(NSSize(width: 480, height: 480 * size.height / size.width))
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.minY + 24))
        } else {
            let width = panel.contentLayoutRect.width
            let top = panel.frame.maxY
            panel.setContentSize(NSSize(width: width, height: width * size.height / size.width))
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
        panel.setFrameAutosaveName(Self.frameName)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Torna nella finestra principale: il pannello si chiude ma il video va avanti.
    func expand() {
        guard let vm = activeVM else { return }
        keepPlayingOnClose = true
        close(stopping: false)
        restoring = vm
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }

    /// Il player è stato riaperto nella finestra (o ne è stato aperto un
    /// altro): il pannello si chiude, fermando il video solo se è un altro.
    func playerOpened(_ vm: PlayerViewModel) {
        guard let active = activeVM else { return }
        if active === vm {
            keepPlayingOnClose = true
            close(stopping: false)
        } else {
            close(stopping: true)
        }
    }

    private func close(stopping: Bool) {
        let vm = activeVM
        activeVM = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        if stopping { vm?.stop() }
        keepPlayingOnClose = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Chiusura dall'esterno (es. ⌘W col pannello in primo piano).
        MainActor.assumeIsolated { close(stopping: !keepPlayingOnClose) }
    }

    private static let frameName = "CurfsMiniPlayer"

    private static func videoSize(of vm: PlayerViewModel) -> NSSize {
        let size = vm.player.currentItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return NSSize(width: 16, height: 9) }
        return size
    }
}

private struct MacMiniPlayerContent: View {
    let vm: PlayerViewModel
    let onExpand: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            MacVideoPlayerView(
                player: vm.player,
                onSkip: { vm.skip(by: $0) },
                onRateChange: { vm.setPlaybackRate($0) },
                isCompact: true
            )

            // Striscia in alto per trascinare la finestra (sul video i clic
            // vanno ai controlli del player), con i due tasti.
            HStack(spacing: 8) {
                circleButton("xmark", help: "Chiudi", action: onClose)
                Spacer()
                circleButton("arrow.up.left.and.arrow.down.right", help: "Torna alla finestra", action: onExpand)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .opacity(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
        }
        .background(.black)
        .ignoresSafeArea()
        .onHover { isHovering = $0 }
    }

    private func circleButton(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .help(help)
    }
}
