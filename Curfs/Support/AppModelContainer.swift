//
//  AppModelContainer.swift
//  Curfs
//
//  Un unico `ModelContainer` condiviso da tutta l'app. Serve perché non
//  tutto ciò che scrive nella libreria vive dentro l'albero delle view: il
//  completamento di un download in background può avvenire dopo che iOS ha
//  rilanciato l'app *senza* interfaccia (solo per consegnare gli eventi di
//  URLSession), quindi lì non c'è nessun `@Environment(\.modelContext)` da
//  cui pescare. `RemoteDownloadManager` usa `ModelContext(AppModelContainer.shared)`
//  in quei casi; la scena SwiftUI usa lo stesso container via
//  `.modelContainer(AppModelContainer.shared)`.
//

import Foundation
import SwiftData

enum AppModelContainer {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: MediaItem.self)
        } catch {
            fatalError("Impossibile creare il ModelContainer condiviso: \(error)")
        }
    }()
}
