//
//  SearchResultCard.swift
//  Curfs
//
//  Card di un risultato di ricerca remoto: a differenza delle card della
//  libreria (che mostrano un frame reale del video), qui mostriamo il
//  poster ufficiale in verticale, tipico di un catalogo remoto.
//

import SwiftUI

struct SearchResultCard: View {
    let title: RemoteTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)

            Text(title.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Image(systemName: title.kind == .movie ? "film" : "tv")
                if let year = title.year, !year.isEmpty {
                    Text(year)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = title.posterURL {
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
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: title.kind == .movie ? "film" : "tv")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
            }
    }
}
