//
//  PlayerControlsOverlay.swift
//  Curfs
//
//  I controlli sovrapposti al video, tutti in Liquid Glass nativo: barra in
//  alto con titolo/chiusura/rotazione, play/pausa e skip al centro (che si
//  fondono tra loro nello stesso GlassEffectContainer), slider di sistema
//  in basso con i tempi. Nessun pannello/sfondo dietro: solo i controlli
//  "fluttuano" sul video, come i controlli nativi di sistema.
//

import SwiftUI

private let availableRates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

/// Tinta scura applicata a tutti i pulsanti in glass: il Liquid Glass
/// "regular" è adattivo ma resta molto trasparente, e su scene chiare (es.
/// sfondo bianco) i simboli bianchi perdono contrasto ("bolle" quasi
/// invisibili). Una tinta nera leggera scurisce il vetro in modo uniforme,
/// così il contrasto col simbolo bianco sopra resta leggibile qualunque sia
/// il contenuto del video dietro.
private let buttonGlassTint = Color.black.opacity(0.4)

struct PlayerControlsOverlay: View {
    let vm: PlayerViewModel
    var onClose: () -> Void
    var onNextEpisode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerControls
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                glassIconButton("chevron.down", action: onClose)

                VStack(alignment: .leading, spacing: 2) {
                    if let show = vm.item.showName, let code = vm.item.episodeCode {
                        Text(show)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(code) · \(vm.item.title)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    } else {
                        Text(vm.item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(.top, 6)

                Spacer()

                if vm.nextEpisode != nil {
                    glassIconButton("forward.end.fill", action: onNextEpisode)
                }

                glassIconButton(vm.isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                    vm.toggleOrientation()
                }

                speedMenu
            }
        }
        .glassEffectTransition(.materialize)
    }

    private func glassIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .tint(buttonGlassTint)
        .buttonBorderShape(.circle)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(availableRates, id: \.self) { rate in
                Button {
                    vm.setPlaybackRate(rate)
                } label: {
                    if rate == vm.playbackRate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(rateLabel(vm.playbackRate))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .tint(buttonGlassTint)
        .padding(.top, 3)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == 1.0 ? "1x" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))x" : "\(rate)x")
    }

    private var centerControls: some View {
        GlassEffectContainer(spacing: 30) {
            HStack(spacing: 30) {
                skipButton("gobackward.10") { vm.skip(by: -10) }

                Button(action: vm.togglePlayPause) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor.opacity(0.55))
                .buttonBorderShape(.circle)

                skipButton("goforward.10") { vm.skip(by: 10) }
            }
        }
        .glassEffectTransition(.materialize)
    }

    private func skipButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .tint(buttonGlassTint)
        .buttonBorderShape(.circle)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.currentTime = $0 }
                ),
                in: 0...max(vm.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        vm.beginScrubbing()
                    } else {
                        vm.endScrubbing(to: vm.currentTime)
                    }
                }
            )
            .tint(Color.accentColor)
            .disabled(!vm.isDurationReady)
            .animation(.easeOut(duration: 0.2), value: vm.isDurationReady)

            HStack {
                Text(TimeFormatter.format(vm.currentTime))
                    .monospacedDigit()
                Spacer()
                Text("-" + TimeFormatter.format(max(vm.duration - vm.currentTime, 0)))
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 3)
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
