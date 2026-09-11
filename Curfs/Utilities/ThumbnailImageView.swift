//
//  ThumbnailImageView.swift
//  Curfs
//
//  Mostra la miniatura salvata su disco per un MediaItem, con un placeholder
//  animato finché non è pronta (viene generata in background all'import).
//

import SwiftUI

struct ThumbnailImageView: View {
    let item: MediaItem
    var systemFallback: String = "film"

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else {
                LinearGradient(
                    colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
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
        guard uiImage == nil else { return }
        if let image = await Self.readFromDisk(item.thumbnailURL) {
            uiImage = image
            return
        }
        // Manca sul disco (es. il sistema ha svuotato la cache, o il file è
        // andato perso in altro modo): rigenerala al volo invece di restare
        // grigia per sempre. `generateIfNeeded` non rifà nulla se il file
        // c'è già, quindi qui costa solo quando serve davvero.
        await ThumbnailGenerator.generateIfNeeded(for: item)
        if let image = await Self.readFromDisk(item.thumbnailURL) {
            uiImage = image
        }
    }

    private static func readFromDisk(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
