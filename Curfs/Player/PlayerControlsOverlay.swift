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
    var showsPictureInPicture = false
    var onPictureInPicture: () -> Void = {}
    /// Curfs AI (solo dove c'è Apple Intelligence): sempre in vista, anche
    /// nella barra compatta.
    var showsCompanion = false
    var onCompanion: () -> Void = {}
    var onClose: () -> Void
    var onNextEpisode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerControls
            Spacer(minLength: 0)
            PlayerTimeBar(vm: vm)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// Con spazio a sufficienza tutti i tasti in fila; se il titolo verrebbe
    /// tagliato (iPhone stretti, verticale), quelli secondari vanno nel "⋯".
    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                topBarRow(compact: false)
                topBarRow(compact: true)
            }
        }
        .glassEffectTransition(.materialize)
    }

    private func topBarRow(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            glassIconButton("chevron.down", action: onClose)

            // Nella versione completa il titolo non si accorcia mai: se non
            // ci sta per intero, ViewThatFits passa a quella compatta.
            titleBlock
                .fixedSize(horizontal: !compact, vertical: false)

            Spacer(minLength: 0)

            if !compact {
                if showsPictureInPicture {
                    glassIconButton("pip.enter", action: onPictureInPicture)
                        .accessibilityLabel("Picture in Picture")
                }
                if vm.nextEpisode != nil {
                    glassIconButton("forward.end.fill", action: onNextEpisode)
                        .accessibilityLabel("Episodio successivo")
                }
            }

            if showsCompanion {
                glassIconButton("sparkles", action: onCompanion)
                    .accessibilityLabel(Text(verbatim: "Curfs AI"))
            }

            glassIconButton(vm.isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                vm.toggleOrientation()
            }

            if compact {
                PlayerOptionsMenu(
                    vm: vm,
                    showsPictureInPicture: showsPictureInPicture,
                    onPictureInPicture: onPictureInPicture,
                    onNextEpisode: onNextEpisode
                )
            } else {
                TracksMenu(tracks: TrackState(vm), vm: vm)
                    .equatable()
                PlaybackSpeedMenu(vm: vm)
            }
        }
    }

    private var titleBlock: some View {
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
}

/// Barra del tempo in una view a sé: è l'unica parte dei controlli che legge
/// `currentTime` (cambia 4 volte al secondo). Se la leggesse il body di
/// PlayerControlsOverlay, a ogni tick si ricostruirebbe tutta la barra in alto
/// e con lei il menu tracce aperto: scorrendolo tornava in cima e le voci si
/// sovrapponevano in dissolvenza.
private struct PlayerTimeBar: View {
    let vm: PlayerViewModel

    var body: some View {
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

/// Velocità come tasto a sé (barra completa). `Picker` nativo dentro un
/// `Menu`, in una view che legge solo `playbackRate`: vedi PlayerOptionsMenu.
private struct PlaybackSpeedMenu: View {
    let vm: PlayerViewModel

    var body: some View {
        Menu {
            Picker("Velocità di riproduzione", selection: Binding(
                get: { vm.playbackRate },
                set: { vm.setPlaybackRate($0) }
            )) {
                ForEach(availableRates, id: \.self) { rate in
                    Text(verbatim: rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: rateLabel(vm.playbackRate))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.glass)
        .tint(buttonGlassTint)
        .padding(.top, 3)
        .simultaneousGesture(TapGesture().onEnded { vm.holdControls() })
    }
}

/// Tracce e scelta attuale, copiate dal view model: il menu tracce dipende
/// solo da questi valori (vedi TracksMenu).
private struct TrackState: Equatable {
    let audio: [PlayerViewModel.TrackChoice]
    let subtitles: [PlayerViewModel.TrackChoice]
    let selectedAudio: Int?
    let selectedSubtitle: Int?

    @MainActor init(_ vm: PlayerViewModel) {
        audio = vm.audioTracks
        subtitles = vm.subtitleTracks
        selectedAudio = vm.selectedAudioTrack
        selectedSubtitle = vm.selectedSubtitleTrack
    }
}

/// Audio e sottotitoli come tasto a sé (barra completa), solo se il file ne
/// ha da scegliere. `Equatable` sui soli valori delle tracce (`.equatable()`
/// dove si usa) e nessuna lettura del view model nel body: se la barra in
/// alto si ridisegna, il menu aperto non viene ricostruito (scorrendolo
/// tornava in cima e le voci sfumavano).
private struct TracksMenu: View, Equatable {
    let tracks: TrackState
    let vm: PlayerViewModel

    nonisolated static func == (lhs: TracksMenu, rhs: TracksMenu) -> Bool {
        lhs.tracks == rhs.tracks
    }

    var body: some View {
        if tracks.audio.count > 1 || !tracks.subtitles.isEmpty {
            // Liste piatte, non sottomenu: nei sottomenu non si può trascinare
            // il dito e rilasciare sulla voce (era quello il "tocco rotto").
            Menu {
                TrackPickers(tracks: tracks, vm: vm, inline: true)
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .buttonStyle(.glass)
            .tint(buttonGlassTint)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Sottotitoli")
            .simultaneousGesture(TapGesture().onEnded { vm.holdControls() })
        }
    }
}

/// Sottotitoli/audio, condivisi tra TracksMenu (liste piatte con
/// intestazione) e il "⋯" (sottomenu, mostrano anche la scelta attuale).
private struct TrackPickers: View {
    let tracks: TrackState
    let vm: PlayerViewModel
    let inline: Bool

    var body: some View {
        if !tracks.subtitles.isEmpty {
            styled(Picker(selection: Binding(
                get: { tracks.selectedSubtitle },
                set: { vm.selectSubtitleTrack($0) }
            )) {
                Text("Disattivati").tag(Int?.none)
                ForEach(tracks.subtitles) { track in
                    Text(verbatim: track.name).tag(Int?.some(track.id))
                }
            } label: {
                Label("Sottotitoli", systemImage: "captions.bubble")
            }, title: "Sottotitoli", icon: "captions.bubble")
        }

        if tracks.audio.count > 1 {
            styled(Picker(selection: Binding(
                get: { tracks.selectedAudio ?? 0 },
                set: { vm.selectAudioTrack($0) }
            )) {
                ForEach(tracks.audio) { track in
                    Text(verbatim: track.name).tag(track.id)
                }
            } label: {
                Label("Audio", systemImage: "waveform")
            }, title: "Audio", icon: "speaker.wave.2")
        }
    }

    @ViewBuilder
    private func styled(_ picker: some View, title: LocalizedStringKey, icon: String) -> some View {
        if inline {
            // In cima a ogni lista una riga grigia non cliccabile con icona e
            // nome: i titoli di sezione dei menu iOS (Section, label del
            // Picker in linea) sull'iPhone non comparivano proprio. Una Label
            // semplice, non un Button disattivato: la sua azione (una closure)
            // risulta sempre diversa e faceva ricostruire il menu aperto.
            Section {
                Label(title, systemImage: icon)
                picker.pickerStyle(.inline).labelsHidden()
            }
        } else {
            picker.pickerStyle(.menu)
        }
    }
}

private func rateLabel(_ rate: Double) -> String {
    rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))x" : "\(rate)x"
}

/// Barra compatta (il titolo non ci starebbe): tutto il resto nel "⋯", episodio
/// successivo, Picture-in-Picture e, come sottomenu nativi (`Picker` con
/// stile `.menu`, mostrano anche la scelta attuale), velocità, sottotitoli e
/// audio. Sta in una view a sé apposta: non legge `currentTime`, che cambia
/// più volte al secondo e ridisegnando il menu aperto gli faceva perdere il
/// tocco scorrendoci sopra.
private struct PlayerOptionsMenu: View {
    let vm: PlayerViewModel
    let showsPictureInPicture: Bool
    let onPictureInPicture: () -> Void
    let onNextEpisode: () -> Void

    var body: some View {
        Menu {
            Section {
                if vm.nextEpisode != nil {
                    Button("Episodio successivo", systemImage: "forward.end.fill", action: onNextEpisode)
                }
                if showsPictureInPicture {
                    Button("Picture in Picture", systemImage: "pip.enter", action: onPictureInPicture)
                }
            }
            Section {
                Picker(selection: Binding(
                    get: { vm.playbackRate },
                    set: { vm.setPlaybackRate($0) }
                )) {
                    ForEach(availableRates, id: \.self) { rate in
                        Text(verbatim: rateLabel(rate)).tag(rate)
                    }
                } label: {
                    Label("Velocità di riproduzione", systemImage: "gauge.with.dots.needle.67percent")
                }
                .pickerStyle(.menu)

                TrackPickers(tracks: TrackState(vm), vm: vm, inline: false)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.glass)
        .tint(buttonGlassTint)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Altre opzioni")
        // Aprendo il menu i controlli non devono sparire sotto il dito.
        .simultaneousGesture(TapGesture().onEnded { vm.holdControls() })
    }
}
