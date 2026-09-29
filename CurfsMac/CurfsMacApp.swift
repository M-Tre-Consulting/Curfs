//
//  CurfsMacApp.swift
//  CurfsMac
//
//  Punto d'ingresso della versione Mac di Curfs. A differenza di CurfsApp
//  (iOS) non serve un AppDelegate: niente rotazione da gestire, la finestra
//  è semplicemente ridimensionabile da subito. Riusa RootTabView e tutto lo
//  strato Modelli/Support/Remote/Views condiviso con l'app iOS — solo il
//  player (Player/Mac*.swift) è specifico di questo target.
//

import SwiftUI
import SwiftData

@main
struct CurfsMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                LegalMenuButton()
            }
        }

        // "Privacy, licenza e contatti" di M-Tre Consulting (vedi Branding).
        Window("Privacy, licenza e contatti", id: LegalMenuButton.windowID) {
            LegalView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// Voce del menu Curfs che apre la finestra delle informazioni legali.
private struct LegalMenuButton: View {
    static let windowID = "legal"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Privacy, licenza e contatti…") {
            openWindow(id: Self.windowID)
        }
    }
}
