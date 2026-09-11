//
//  FrameHasher.swift
//  Curfs
//
//  Hash percettivo di un fotogramma (difference hash, 8x8 = 64 bit): due
//  fotogrammi visivamente simili producono hash con pochi bit diversi. Usato
//  per confrontare fotogrammi tra episodi diversi senza doverli confrontare
//  pixel per pixel — è il mattoncino su cui si basa il riconoscimento reale
//  di sigla/titoli di coda in IntroCreditsAnalyzer.
//

import CoreGraphics

nonisolated enum FrameHasher {
    private static let gridSize = 9 // 9 campioni per riga/colonna -> 8x8 differenze = 64 bit

    /// Sotto questa escursione min/max di luminosità (su 255) un fotogramma è
    /// considerato "degenere": nero/quasi nero, dissolvenza, schermata a
    /// tinta unita, logo di rete... Va scartato invece di essere hashato,
    /// perché produce comunque un hash pressoché costante che combacerebbe
    /// con QUALSIASI altro fotogramma altrettanto piatto di un episodio
    /// completamente diverso (tipicamente il primo/ultimo secondo, in
    /// dissolvenza da/a nero) — è la causa reale dei falsi positivi che
    /// facevano comparire "salta intro" in un punto sbagliato.
    private static let minLumaRange: UInt8 = 14

    static func hash(_ image: CGImage) -> UInt64? {
        let size = gridSize
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let minPixel = pixels.min(), let maxPixel = pixels.max(),
              maxPixel - minPixel >= minLumaRange else { return nil }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<(size - 1) {
            for col in 0..<(size - 1) {
                let left = pixels[row * size + col]
                let right = pixels[row * size + col + 1]
                if left < right { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
