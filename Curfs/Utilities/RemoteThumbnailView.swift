//
//  RemoteThumbnailView.swift
//  Curfs
//
//  Miniatura di un episodio che sta solo sul server (nessun MediaItem in
//  libreria): stesso fotogramma di `ThumbnailGenerator`, preso dal file
//  remoto con richieste Range, salvato su disco per URL. Prima quelle righe
//  della scheda serie mostravano un riquadro grigio.
//
//  Al massimo 2 generazioni insieme: una stagione intera aperta di colpo
//  non deve sparare 10 connessioni al Pi.
//

import SwiftUI
import ImageIO
import CryptoKit
@preconcurrency import AVFoundation

struct RemoteThumbnailView: View {
    let url: URL
    var systemFallback: String = "tv"

    @State private var cgImage: CGImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let cgImage {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                } else {
                    LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: systemFallback)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            cgImage = await RemoteThumbnailCache.shared.image(for: url)
        }
    }
}

actor RemoteThumbnailCache {
    static let shared = RemoteThumbnailCache()

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return LibraryStorage.thumbnailsDirectory.appending(path: "remote-\(name).jpg")
    }

    func image(for url: URL) async -> CGImage? {
        let file = Self.fileURL(for: url)
        if let image = Self.read(file) { return image }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if let image = Self.read(file) { return image }

        let headers = RemoteSourceStore.current.authHeaders
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        await ThumbnailGenerator.generate(asset: asset, destination: file, duration: seconds.isFinite ? seconds : 0)
        return Self.read(file)
    }

    private func acquire() async {
        if running < 2 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    private static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
