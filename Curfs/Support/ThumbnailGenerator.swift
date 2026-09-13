//
//  ThumbnailGenerator.swift
//  Curfs
//
//  Genera e mette in cache su disco una miniatura JPG per un MediaItem,
//  prendendo un frame un po' dentro il video (non il primo, spesso nero).
//  Funziona identica per un item locale e per uno in streaming dal server
//  remoto: `AVAssetImageGenerator` scarica via richieste Range solo i pochi
//  byte del fotogramma richiesto, non l'intero file — non più pesante del
//  collegamento al Pi già fatto per lo streaming stesso (vedi
//  `PlayerViewModel.makePlayer`, stesso pattern di header di autenticazione).
//
//  Codifica JPEG via ImageIO (CGImageDestination) invece di UIImage/NSImage:
//  è l'unica via cross-platform, così questo file è condiviso tra il target
//  iOS e quello macOS senza bisogno di conditional compilation.
//

import Foundation
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailGenerator {
    static func generateIfNeeded(for item: MediaItem) async {
        let destination = item.thumbnailURL
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let asset = makeAsset(for: item)

        // Un item remoto appena aggiunto alla libreria (senza averlo ancora
        // mai riprodotto) ha `duration == 0`: per l'import locale/il download
        // la durata è già nota a questo punto (misurata prima altrove), qui
        // no. Senza, il target scelto sotto cade sempre a t=0 — quasi sempre
        // nero — e ci resta per sempre, perché una volta scritta la
        // miniatura su disco non viene più rigenerata. Misurarla qui replica
        // lo stesso procedimento del caso locale invece di accontentarsi del
        // primo fotogramma; la scriviamo anche sul modello, di rimbalzo
        // sistema anche la durata mostrata prima ancora del primo play.
        var duration = item.duration
        if item.isRemote && duration <= 0 {
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds >= 1 {
                duration = seconds
                item.duration = seconds
            }
        }

        await generate(asset: asset, destination: destination, duration: duration)
    }

    private static func makeAsset(for item: MediaItem) -> AVURLAsset {
        guard item.isRemote else { return AVURLAsset(url: item.fileURL) }
        let headers = RemoteSourceStore.current.authHeaders
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: item.playbackURL, options: options)
    }

    static func generate(asset: AVURLAsset, destination: URL, duration: Double) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let targetSeconds = duration > 4 ? min(duration * 0.1, 30) : 0
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: time).image else { return }
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
