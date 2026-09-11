//
//  ThumbnailGenerator.swift
//  Curfs
//
//  Genera e mette in cache su disco una miniatura JPG per un MediaItem,
//  prendendo un frame un po' dentro il video (non il primo, spesso nero).
//

import Foundation
@preconcurrency import AVFoundation
import UIKit

enum ThumbnailGenerator {
    static func generateIfNeeded(for item: MediaItem) async {
        // Gli item in streaming non hanno un file locale: niente miniatura
        // generata, le card usano il placeholder a icona.
        guard !item.isRemote else { return }
        let destination = item.thumbnailURL
        if FileManager.default.fileExists(atPath: destination.path) { return }
        await generate(sourceURL: item.fileURL, destination: destination, duration: item.duration)
    }

    static func generate(sourceURL: URL, destination: URL, duration: Double) async {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let targetSeconds = duration > 4 ? min(duration * 0.1, 30) : 0
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: time).image else { return }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}
