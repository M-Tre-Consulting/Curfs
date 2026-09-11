//
//  ThumbnailImageView.swift
//  Curfs
//
//  Mostra la miniatura salvata su disco per un MediaItem, con un placeholder
//  animato finché non è pronta (viene generata in background all'import).
//
//  Carica via CGImage (ImageIO) invece di UIImage/NSImage — è l'unica via
//  cross-platform, così questo file è condiviso tra il target iOS e quello
//  macOS. Stesso motivo per i colori del placeholder: valori RGB espliciti
//  invece di Color(.secondarySystemBackground) (solo iOS, basato su UIColor).
//

import SwiftUI
import ImageIO

struct ThumbnailImageView: View {
    let item: MediaItem
    var systemFallback: String = "film"

    @State private var cgImage: CGImage?

    var body: some View {
        ZStack {
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else {
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: systemFallback)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.thumbnailURL) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        guard cgImage == nil else { return }
        if let image = await Self.readFromDisk(item.thumbnailURL) {
            cgImage = image
            return
        }
        // Manca sul disco (es. il sistema ha svuotato la cache, o il file è
        // andato perso in altro modo): rigenerala al volo invece di restare
        // grigia per sempre. `generateIfNeeded` non rifà nulla se il file
        // c'è già, quindi qui costa solo quando serve davvero.
        await ThumbnailGenerator.generateIfNeeded(for: item)
        if let image = await Self.readFromDisk(item.thumbnailURL) {
            cgImage = image
        }
    }

    private static func readFromDisk(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
    }
}
