//
//  WindowChrome.swift
//  Curfs
//
//  Su Mac la barra in alto della finestra (titolo + toolbar + selettore
//  delle sezioni) ha un proprio sfondo, che SwiftUI mostra o nasconde a
//  seconda della fase: all'apertura compariva come una fascia nera sopra
//  AppBackground, cambiando sezione spariva, tornando indietro restava
//  sparita. Qui lo si nasconde sempre, così dietro la barra c'è lo stesso
//  sfondo viola del resto della finestra. Su iPhone non fa nulla (lì la
//  barra in Liquid Glass è già quella giusta).
//

import SwiftUI

extension View {
    func cleanWindowToolbar() -> some View {
        #if os(macOS)
        toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }
}
