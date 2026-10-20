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
    init() {
        // Says when there's a new version (DMG copies only: the App Store updates its own).
        Updates.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                // Lo sfondo viola sta anche sulla finestra stessa, non solo
                // dentro le schermate: durante i cambi di sezione (dissolvenza
                // tra le due NavigationStack) non si vede più il nero della
                // finestra tra una e l'altra. Vedi anche WindowChrome.
                .containerBackground(for: .window) { AppBackground() }
                .cleanWindowToolbar()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                LegalMenuButton()
                if !Updater.isFromAppStore {
                    Button("Controlla aggiornamenti…") { Updates.shared.checkFromMenu() }
                }
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

/// Gli aggiornamenti di Curfs per Mac: la versione da mtre-consulting.it/aggiornamenti/curfs-mac,
/// il pulsante verso l'App Store (Support/Updater.swift). `appStore` va messo quando Curfs è sullo store.
@MainActor
enum Updates {
    static let shared = Updater(slug: "curfs-mac", appStore: nil,
                                site: URL(string: "https://mtre-consulting.it/progetti/curfs")!)
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
