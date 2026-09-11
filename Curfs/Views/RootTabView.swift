//
//  RootTabView.swift
//  Curfs
//
//  Tab bar di primo livello: Libreria (Home) e Cerca (Search). Su iOS 26 la
//  TabView con l'API Tab(...) usa già di default la tab bar in Liquid Glass
//  nativa: non serve nessun modifier aggiuntivo per l'aspetto, la transizione
//  tra le due sezioni è già quella di sistema.
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            Tab("Libreria", systemImage: "film.stack") {
                LibraryHomeView()
            }

            Tab("Cerca", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
        .task {
            // Scalda l'analisi "salta intro" di tutta la libreria locale, così
            // il pulsante c'è alla prima riproduzione (vedi IntroCreditsWarmup).
            await IntroCreditsWarmup.run(modelContext: modelContext)
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: MediaItem.self, inMemory: true)
        .preferredColorScheme(.dark)
}
