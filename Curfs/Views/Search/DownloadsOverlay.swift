//
//  DownloadsOverlay.swift
//  Curfs
//
//  Download in corso nella sezione Cerca: un tasto rotondo in Liquid Glass in
//  basso a destra (solo la freccia giù) che, toccato, apre un popover di
//  sistema (con la sua animazione) alto quanto i download presenti; la X o un
//  tocco fuori lo richiudono.
//  Prima era un pannello con una riga per download largo tutto lo schermo:
//  scaricando una stagione intera copriva mezza pagina.
//

import SwiftUI

struct DownloadsOverlay: View {
    var manager: RemoteDownloadManager

    @State private var isExpanded = false

    var body: some View {
        toggleButton
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                panel
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var toggleButton: some View {
        Button {
            isExpanded = true
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(Text("Download in corso"))
    }

    /// Alto quanto le righe che contiene; se non ci stanno nello spazio che il
    /// popover ha sullo schermo, le righe scorrono dentro.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Download in corso")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Chiudi"))
            }

            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
                    .scrollIndicators(.hidden)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(manager.items) { item in
                row(for: item)
            }
        }
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
                    .lineLimit(1)
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
            return String(localized: "In pausa • \(Int(progress * 100))% — riprendo da qui")
        case .finalizing:
            return String(localized: "Sto completando…")
        case .completed:
            return String(localized: "Completato")
        case .failed(let message):
            return message
        }
    }
}
