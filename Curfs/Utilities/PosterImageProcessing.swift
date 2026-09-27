//
//  PosterImageProcessing.swift
//  Curfs
//
//  Prepara una copertina scelta dall'utente prima di caricarla sul server:
//  ritaglio centrale a 2:3 (le card la mostrano così, un'immagine con altre
//  proporzioni verrebbe comunque tagliata) e ridimensionamento a 1000x1500
//  al massimo, in JPEG. CoreGraphics/ImageIO invece di UIImage/NSImage così
//  vale per entrambi i target (vedi ThumbnailGenerator).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum PosterImageProcessing {
    static let maxSize = CGSize(width: 1000, height: 1500)

    static func posterJPEG(from data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        // Miniatura "a tutta risoluzione" solo per applicare l'orientamento
        // EXIF (foto scattate in verticale), limitata a una misura ragionevole.
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let targetRatio = maxSize.width / maxSize.height
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > targetRatio {
            crop.size.width = (height * targetRatio).rounded()
            crop.origin.x = ((width - crop.width) / 2).rounded()
        } else {
            crop.size.height = (width / targetRatio).rounded()
            crop.origin.y = ((height - crop.height) / 2).rounded()
        }
        guard let cropped = image.cropping(to: crop) else { return nil }

        let scale = min(1, maxSize.width / crop.width)
        let outW = Int((crop.width * scale).rounded())
        let outH = Int((crop.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let output = context.makeImage() else { return nil }

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }
}
