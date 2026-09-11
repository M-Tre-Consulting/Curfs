//
//  DownloadsOverlay.swift
//  Curfs
//
//  Pannello flottante in Liquid Glass con lo stato dei download in corso
//  nella sezione Search, sullo stile di ImportProgressOverlay ma non
//  bloccante: resta ancorato in basso mentre si continua a cercare/navigare.
//

import SwiftUI

struct DownloadsOverlay: View {
    var manager: RemoteDownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(manager.items) { item in
                row(for: item)
            }
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 8)
        .padding(.horizontal)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.25), value: manager.items.map(\.id))
    }

    @ViewBuilder
    private func row(for item: RemoteDownloadItem) -> some View {
        HStack(spacing: 10) {
            icon(for: item.state)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(statusText(for: item.state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch item.state {
            case .downloading:
                iconButton("xmark.circle.fill") { manager.cancel(id: item.id) }
            case .paused:
                iconButton("arrow.clockwise.circle.fill", tint: Color.accentColor) { manager.retry(id: item.id) }
                iconButton("xmark.circle.fill") { manager.cancel(id: item.id) }
            case .failed:
                iconButton("arrow.clockwise.circle.fill", tint: Color.accentColor) { manager.retry(id: item.id) }
                iconButton("xmark.circle.fill") { manager.dismiss(id: item.id) }
            case .completed:
                iconButton("xmark.circle.fill") { manager.dismiss(id: item.id) }
            case .finalizing:
                EmptyView()
            }
        }
    }

    private func iconButton(_ systemName: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func icon(for state: RemoteDownloadState) -> some View {
        switch state {
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(Color.accentColor)
        case .paused(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(.secondary)
        case .finalizing:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.accentColor)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.white, .red)
        }
    }

    private func statusText(for state: RemoteDownloadState) -> String {
        switch state {
        case .downloading(let progress):
            return "\(Int(progress * 100))%"
        case .paused(let progress):
            return "In pausa • \(Int(progress * 100))% — riprendo da qui"
        case .finalizing:
            return "Sto completando…"
        case .completed:
            return "Completato"
        case .failed(let message):
            return message
        }
    }
}
