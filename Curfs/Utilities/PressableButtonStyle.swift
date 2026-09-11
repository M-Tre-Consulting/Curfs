//
//  PressableButtonStyle.swift
//  Curfs
//
//  Piccolo effetto "si schiaccia" al tap, usato dalle card di libreria/Cerca.
//  Vive qui (non in Player/) perché non ha nulla a che fare col player: era
//  finita per errore in PlayerControlsOverlay.swift, da cui LibraryHomeView
//  e SearchView la importavano implicitamente; spostata qui quando il target
//  Mac (che non compila Player/PlayerControlsOverlay.swift, iOS-only) ne ha
//  fatto emergere la dipendenza nascosta.
//

import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
