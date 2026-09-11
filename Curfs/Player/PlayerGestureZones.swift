//
//  PlayerGestureZones.swift
//  Curfs
//
//  Doppio tap sulla metà sinistra/destra del video per saltare indietro o
//  avanti, come YouTube/Netflix: tap ripetuti accumulano i secondi mostrati
//  nella bolla, un singolo tap (in qualsiasi punto) mostra/nasconde i controlli.
//
//  Nota tecnica: qui il doppio tap è riconosciuto "a mano" confrontando i
//  timestamp di due tap consecutivi, invece di usare due
//  .onTapGesture(count: 1) / .onTapGesture(count: 2) sulla stessa vista.
//  Con quell'approccio SwiftUI deve aspettare ~300ms dopo ogni tap singolo
//  per essere sicuro che non stia arrivando un secondo tap: il risultato è
//  un tap singolo (mostra/nascondi controlli) percepito come "in ritardo".
//  Così invece il tap singolo reagisce subito, sempre.
//

import SwiftUI

struct PlayerGestureZones: View {
    let vm: PlayerViewModel

    @State private var leftSeconds = 0
    @State private var rightSeconds = 0
    @State private var leftResetTask: Task<Void, Never>?
    @State private var rightResetTask: Task<Void, Never>?
    @State private var lastLeftTap: Date?
    @State private var lastRightTap: Date?

    private let doubleTapWindow: TimeInterval = 0.3

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                zone(seconds: leftSeconds, systemName: "gobackward") { handleTap(isLeft: true) }
                    .frame(width: geo.size.width * 0.4)

                Color.clear
                    .frame(width: geo.size.width * 0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.toggleControls() }

                zone(seconds: rightSeconds, systemName: "goforward") { handleTap(isLeft: false) }
                    .frame(width: geo.size.width * 0.4)
            }
        }
    }

    @ViewBuilder
    private func zone(seconds: Int, systemName: String, onTap: @escaping () -> Void) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

            if seconds != 0 {
                flashBubble(seconds: seconds, systemName: systemName)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private func flashBubble(seconds: Int, systemName: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .semibold))
            Text("\(abs(seconds))s")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .frame(width: 80, height: 80)
        .background(.black.opacity(0.45), in: Circle())
        .allowsHitTesting(false)
    }

    private func handleTap(isLeft: Bool) {
        let now = Date()
        let last = isLeft ? lastLeftTap : lastRightTap

        if let last, now.timeIntervalSince(last) < doubleTapWindow {
            // Tap ravvicinato: salta, e aggiorna il timestamp (non azzerarlo)
            // così un tap ANCORA successivo entro la finestra continua la
            // sequenza invece di essere trattato come un tap "singolo" da
            // capo — altrimenti con 3+ tap rapidi si alternava
            // salto/mostra-nascondi-controlli invece di accumulare i salti
            // come promesso in cima al file ("i tap ripetuti accumulano").
            if isLeft { lastLeftTap = now } else { lastRightTap = now }
            registerSkip(isLeft: isLeft)
        } else {
            // Primo tap: reagisce subito, nessuna attesa.
            if isLeft { lastLeftTap = now } else { lastRightTap = now }
            vm.toggleControls()
        }
    }

    private func registerSkip(isLeft: Bool) {
        vm.skip(by: isLeft ? -10 : 10)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if isLeft { leftSeconds -= 10 } else { rightSeconds += 10 }
        }
        scheduleReset(isLeft: isLeft)
    }

    private func scheduleReset(isLeft: Bool) {
        let task = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                if isLeft { leftSeconds = 0 } else { rightSeconds = 0 }
            }
        }
        if isLeft {
            leftResetTask?.cancel()
            leftResetTask = task
        } else {
            rightResetTask?.cancel()
            rightResetTask = task
        }
    }
}
