//
//  AppBackground.swift
//  Curfs
//
//  Sfondo immersivo viola scuro con qualche "luce" sfocata: dietro ci vanno
//  le superfici in Liquid Glass, che su questo tipo di fondo rendono al meglio.
//

import SwiftUI

struct AppBackground: View {
    var body: some View {
        // GeometryReader qui non è decorativo: senza, i Circle a dimensione
        // fissa qui sotto (440/380/320pt) "trapelano" come ideal-size
        // dell'intero ZStack verso l'alto quando qualcuno (NavigationStack/
        // TabView, in una fase del layout) chiede ad AppBackground "quanto
        // sei largo senza vincoli" — un `.frame(maxWidth: .infinity)` da solo
        // NON basta, perché con una proposta "nil" si limita a inoltrarla al
        // figlio invece di forzare un riempimento. Risultato reale misurato:
        // su schermi più stretti del cerchio più grande (440pt: il più largo
        // tra gli iPhone arriva a 430) lo ZStack che contiene questo sfondo
        // finiva centrato su una larghezza fittizia di 440pt invece che sulla
        // larghezza vera dello schermo, spingendo TUTTO il contenuto della
        // home (card, testi) fuori dal bordo sinistro per metà della
        // differenza — bug reale trovato/confermato misurando la geometria a
        // runtime (vedi CLAUDE.md, "margine perso"), non solo teorico.
        // GeometryReader invece riporta sempre e solo la size che gli viene
        // proposta (mai quella dei figli), tagliando il leak alla radice.
        GeometryReader { _ in
            ZStack {
                Color(red: 0.035, green: 0.02, blue: 0.06)

                LinearGradient(
                    colors: [
                        Color(red: 0.14, green: 0.06, blue: 0.26),
                        Color(red: 0.05, green: 0.02, blue: 0.10),
                        Color(red: 0.02, green: 0.01, blue: 0.05)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.62, green: 0.30, blue: 0.98).opacity(0.38))
                    .frame(width: 440, height: 440)
                    .blur(radius: 130)
                    .offset(x: -150, y: -300)

                Circle()
                    .fill(Color(red: 0.45, green: 0.15, blue: 0.85).opacity(0.30))
                    .frame(width: 380, height: 380)
                    .blur(radius: 140)
                    .offset(x: 170, y: 260)

                Circle()
                    .fill(Color(red: 0.30, green: 0.35, blue: 0.95).opacity(0.22))
                    .frame(width: 320, height: 320)
                    .blur(radius: 120)
                    .offset(x: 130, y: -520)
            }
        }
        .ignoresSafeArea()
    }
}
