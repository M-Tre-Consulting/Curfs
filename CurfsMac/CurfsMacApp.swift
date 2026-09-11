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
    }
}
