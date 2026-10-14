//
//  VideoPlayerLayerView.swift
//  Curfs
//
//  Wrapper UIKit leggero attorno a un AVPlayerLayer: usiamo questo invece del
//  VideoPlayer nativo di SwiftUI perché costruiamo i nostri controlli.
//

import SwiftUI
import AVFoundation

final class PlayerLayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    /// Sempre lo stesso layer, quello a cui è legato il Picture-in-Picture
    /// (vedi PictureInPictureSession).
    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PictureInPictureSession.shared.containerView
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}
