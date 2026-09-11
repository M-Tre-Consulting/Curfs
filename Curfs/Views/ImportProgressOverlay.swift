//
//  ImportProgressOverlay.swift
//  Curfs
//

import SwiftUI

struct ImportProgressOverlay: View {
    let completed: Int
    let total: Int
    let currentName: String

    private var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.25))
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Color.accentColor)

                VStack(spacing: 4) {
                    Text("Importazione in corso")
                        .font(.headline)
                    if total > 0 {
                        Text("\(completed) di \(total) · \(currentName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Analizzo i file selezionati…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(28)
            .glassEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
            .padding(40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}
