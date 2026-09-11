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

import SwiftUI
import AVKit

struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
