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
    #if os(iOS)
    @State private var pip = PictureInPictureSession.shared
    #else
    @State private var miniPlayer = MacMiniPlayer.shared
    #endif

    var body: some View {
        TabView {
            Tab("Libreria", systemImage: "film.stack") {
                LibraryHomeView()
            }

            Tab("Cerca", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
        #if os(iOS)
        // "Ripristina" dalla finestrella del Picture-in-Picture dopo aver
        // chiuso il player: lo riapre da qui, ovunque si sia nell'app.
        .fullScreenCover(item: $pip.restoring) { vm in
            PlayerView(resuming: vm)
        }
        #else
        // "Torna alla finestra" dalla finestra mobile (MacMiniPlayer).
        .sheet(item: $miniPlayer.restoring) { vm in
            MacPlayerView(resuming: vm)
        }
        #endif
        .task {
            // Scalda l'analisi "salta intro" di tutta la libreria locale, così
            // il pulsante c'è alla prima riproduzione (vedi IntroCreditsWarmup).
            await IntroCreditsWarmup.run()
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: MediaItem.self, inMemory: true)
        .preferredColorScheme(.dark)
}
