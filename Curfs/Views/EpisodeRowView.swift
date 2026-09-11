//
//  EpisodeRowView.swift
//  Curfs
//

import SwiftUI

struct EpisodeRowView: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                ThumbnailImageView(item: item, systemFallback: "tv")
                    .aspectRatio(16.0/9.0, contentMode: .fill)
                    .frame(width: 130, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: Color.accentColor.opacity(0.22), radius: 8, y: 4)

                if item.hasProgress {
                    ProgressLineView(fraction: item.progressFraction)
                        .frame(width: 130)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if let code = item.episodeCode {
                    Text(code)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if item.duration > 0 {
                    Text(TimeFormatter.formatCompact(item.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
