//
//  ShowCardView.swift
//  Curfs
//

import SwiftUI

struct ShowCardView: View {
    let show: ShowSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster

            if show.displayProgress > 0.02 {
                ProgressLineView(fraction: show.displayProgress)
            }

            Text(show.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let seasonsText = show.seasons.count > 1 ? "\(show.seasons.count) stagioni" : "1 stagione"
        return "\(seasonsText) · \(show.episodeCount) episodi"
    }

    /// Una serie che viene dal catalogo remoto (in streaming o già scaricata
    /// per intero: vedi `hasRemoteOrigin`) non ha un frame video "di serie"
    /// da mostrare come copertina — usa la locandina ufficiale, come in
    /// Cerca, PER SEMPRE, non solo finché resta in streaming. Una serie mai
    /// passata dal remoto usa invece il frame reale come sempre.
    @ViewBuilder
    private var poster: some View {
        if show.hasRemoteOrigin {
            RemotePosterImage(name: show.name, kind: .series, systemFallback: "tv")
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if show.isStreaming { StreamingBadge() }
                }
                .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)
        } else if let posterItem = show.posterItem {
            ThumbnailImageView(item: posterItem, systemFallback: "tv")
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)
        }
    }
}
