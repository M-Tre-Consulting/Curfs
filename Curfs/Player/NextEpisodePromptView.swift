//
//  NextEpisodePromptView.swift
//  Curfs
//
//  Card che compare negli ultimi secondi di un episodio, con countdown
//  automatico al prossimo — utile quando ci si guarda una stagione intera.
//

import SwiftUI

struct NextEpisodePromptView: View {
    /// Opzionale: la view resta sempre montata (vedi PlayerView) anche
    /// quando non c'è un prossimo episodio o il pannello è nascosto.
    let next: MediaItem?
    /// Vera quando il pannello deve essere visibile: guida l'avvio/lo stop
    /// del countdown, dato che `.onAppear` con la view sempre montata
    /// scatterebbe una sola volta in assoluto invece che ogni volta che
    /// il pannello ricompare.
    let isPresented: Bool
    var onPlayNow: () -> Void
    var onDismiss: () -> Void

    private let countdownSeconds = 8
    @State private var remaining = 8
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .top) {
                Spacer()
                card
            }
        }
        .padding(20)
        .onChange(of: isPresented) { _, presented in
            if presented {
                remaining = countdownSeconds
                startCountdown()
            } else {
                task?.cancel()
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        if let next {
            cardBody(for: next)
        }
    }

    private func cardBody(for next: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    ThumbnailImageView(item: next, systemFallback: "play.tv")
                        .frame(width: 88, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 2)
                        .overlay(
                            Circle()
                                .trim(from: 0, to: CGFloat(remaining) / CGFloat(countdownSeconds))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        )
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Text("\(remaining)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                        .offset(x: 33, y: -15)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Prossimo episodio")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    if let code = next.episodeCode {
                        Text("\(code) · \(next.title)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    } else {
                        Text(next.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: 140, alignment: .leading)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Annulla", action: onDismiss)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.glass)

                    Button(action: onPlayNow) {
                        Label("Riproduci", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.accentColor)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.4), radius: 18, y: 8)
    }

    private func startCountdown() {
        task = Task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            if !Task.isCancelled { onPlayNow() }
        }
    }
}
