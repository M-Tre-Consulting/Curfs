//
//  ContinueWatchingCard.swift
//  Curfs
//
//  Card più larga usata nel binario orizzontale "Continua a guardare".
//

import SwiftUI

struct ContinueWatchingCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ThumbnailImageView(item: item, systemFallback: item.kind == .movie ? "film" : "tv")
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .glassEffect(in: Circle())
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: Color.accentColor.opacity(0.32), radius: 14, y: 7)

            ProgressLineView(fraction: item.progressFraction, height: 4)

            if let show = item.showName, let code = item.episodeCode {
                Text(show).font(.footnote.weight(.medium)).lineLimit(1)
                Text(code + " · " + item.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(1)
                Text(TimeFormatter.formatCompact(max(item.duration - item.playbackPosition, 0)) + " rimasti")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 210)
    }
}
