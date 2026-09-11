//
//  SkipIntroButton.swift
//  Curfs
//
//  Pulsante "Salta intro" mostrato durante la sigla iniziale riconosciuta
//  euristicamente (vedi EpisodeTimeline). Resta visibile indipendentemente
//  dal resto dei controlli, come nelle app di streaming.
//

import SwiftUI

struct SkipIntroButton: View {
    var action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: action) {
                    Label("Salta intro", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor.opacity(0.85))
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 110)
        .transition(.blurReplace.combined(with: .move(edge: .trailing)))
    }
}
