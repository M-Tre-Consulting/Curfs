//
//  RemoteImage.swift
//  Curfs
//
//  Al posto di AsyncImage per le locandine: le copertine dell'utente stanno
//  sul server del Pi, che può chiedere basic-auth — AsyncImage non permette
//  di aggiungere header. Qui gli header di `RemoteSourceStore` vengono
//  mandati solo alle richieste verso quell'host (non a iTunes).
//
//  Come AsyncImage, riempie lo spazio proposto senza una dimensione
//  "naturale" propria solo se il chiamante lo vincola (vedi
//  RemotePosterImage/SearchResultCard e CLAUDE.md).
//

import SwiftUI
import ImageIO

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await RemoteImageLoader.shared.image(for: url)
        }
    }
}

actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, CGImage>()

    func image(for url: URL) async -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        let config = RemoteSourceStore.current
        if let host = url.host, host == config.baseURL?.host {
            for (field, value) in config.authHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        } else if url.host?.hasSuffix("wikimedia.org") == true {
            request.setValue(PosterFetcher.wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
