//
//  MovieCardView.swift
//  Curfs
//

import SwiftUI

struct MovieCardView: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                poster

                if item.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 14))
                        .padding(6)
                        .glassEffect(in: Circle())
                        .padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)

            if item.hasProgress {
                ProgressLineView(fraction: item.progressFraction)
            }

            Text(item.title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            if item.duration > 0 {
                Text(TimeFormatter.formatCompact(item.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un film che viene dal catalogo remoto (in streaming o già scaricato:
    /// vedi `isRemoteOrigin`) usa la locandina ufficiale, come in Cerca, PER
    /// SEMPRE — non solo finché resta in streaming.
    @ViewBuilder
    private var poster: some View {
        if item.isRemoteOrigin {
            RemotePosterImage(name: item.title, kind: .movie, systemFallback: "film")
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if item.isRemote { StreamingBadge() }
                }
        } else {
            ThumbnailImageView(item: item, systemFallback: "film")
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
