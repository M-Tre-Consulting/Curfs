//
//  RemotePosterImage.swift
//  Curfs
//
//  Locandina ufficiale (iTunes, via PosterFetcher) per un titolo interamente
//  in streaming (`ShowSummary.isStreaming` / `MediaItem.isRemote`): prima di
//  scaricare o riprodurre qualunque cosa non abbiamo un frame video "buono"
//  da mostrare come copertina, ma abbiamo il nome — stessa fonte della
//  sezione Cerca (`SearchResultCard`).
//
//  La dimensione è forzata dal contenitore via GeometryReader invece che
//  lasciata alle dimensioni reali dell'immagine scaricata: senza, AsyncImage
//  propone come "ideale" i pixel veri del file (es. 600x900pt) invece di
//  quelli della cella che lo ospita, e la card sfora lo schermo — lo stesso
//  bug isolato in SearchResultCard, vedi CLAUDE.md.
//

import SwiftUI

struct RemotePosterImage: View {
    let name: String
    let kind: RemoteTitleKind
    var systemFallback: String = "film"

    @State private var url: URL?

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .task(id: name) {
            url = await PosterFetcher.shared.posterURL(forName: name, kind: kind)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: systemFallback)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
