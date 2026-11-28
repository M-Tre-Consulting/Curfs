//
//  RecentTitleCard.swift
//  Curfs
//
//  Card dei Contenuti recenti: locandina (o fotogramma per ciò che è stato
//  importato da File), simbolino in alto a sinistra che dice se è scaricato
//  sul dispositivo, scaricato in parte o in streaming, barra di visione e a
//  che punto si è.
//

import SwiftUI

struct RecentTitleCard: View {
    let title: RecentTitle

    var body: some View {
        let resume = title.resume
        VStack(alignment: .leading, spacing: 6) {
            poster(resume: resume?.item)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) { DownloadStateBadge(state: title.downloadState) }
                .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)

            bar(resume)

            Text(title.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(subtitle(resume))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bar(_ resume: (item: MediaItem, isNext: Bool)?) -> some View {
        if let resume, !resume.isNext {
            if resume.item.isFinished {
                EpisodeProgressBar(fraction: 1, isFinished: true)
            } else {
                ProgressLineView(fraction: resume.item.progressFraction)
                    .frame(height: 12)
            }
        } else {
            ProgressLineView(fraction: 0).frame(height: 12)
        }
    }

    private func subtitle(_ resume: (item: MediaItem, isNext: Bool)?) -> String {
        guard let resume else { return "" }
        let item = resume.item
        let code = item.episodeCode
        if resume.isNext, let code { return String(localized: "Prossimo: \(code)") }
        if item.isFinished {
            if let code { return String(localized: "Visto \(code)") }
            return String(localized: "Visto")
        }
        if item.hasProgress, item.duration > 0 {
            let left = TimeFormatter.formatCompact(max(item.duration - item.playbackPosition, 0))
            if let code { return "\(code) · " + String(localized: "\(left) rimasti") }
            return String(localized: "\(left) rimasti")
        }
        if let code { return code }
        return item.duration > 0 ? TimeFormatter.formatCompact(item.duration) : ""
    }

    @ViewBuilder
    private func poster(resume: MediaItem?) -> some View {
        if title.hasRemoteOrigin {
            RemotePosterImage(name: title.name, kind: title.kind == .series ? .series : .movie,
                              systemFallback: title.kind == .series ? "tv" : "film")
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let item = resume ?? title.items.first {
            // Importato da File: nessuna locandina, il fotogramma 2:3 al centro.
            ThumbnailImageView(item: item, systemFallback: title.kind == .series ? "tv" : "film")
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Simbolino sulla card: scaricato (freccia piena), in parte (freccia
/// vuota), in streaming (onde).
struct DownloadStateBadge: View {
    let state: RecentTitle.DownloadState

    var body: some View {
        let (symbol, label): (String, LocalizedStringKey) = switch state {
        case .downloaded: ("arrow.down.circle.fill", "Scaricato")
        case .partial: ("arrow.down.circle", "Scaricato in parte")
        case .streaming: ("dot.radiowaves.left.and.right", "In streaming")
        }
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(state == .streaming ? AnyShapeStyle(.black.opacity(0.45)) : AnyShapeStyle(Color.accentColor.opacity(0.85)), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
            .padding(6)
            .accessibilityLabel(label)
            .help(label)
    }
}
