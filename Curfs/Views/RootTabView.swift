//
//  RootTabView.swift
//  Curfs
//
//  Primo livello: la home con i Contenuti recenti. La scheda Cerca non c'è
//  più (2026-11-28): la Libreria del server si tira fuori dal bordo destro
//  della home (`ServerLibraryDrawerHost`, sopra a tutto, anche alla barra
//  delle schede). Con una sola scheda la barra in basso si nasconde.
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var pip = PictureInPictureSession.shared
    #else
    @State private var miniPlayer = MacMiniPlayer.shared
    #endif

    @State private var profiles = ProfileSync.shared

    var body: some View {
        // Senza profilo non si entra: prima "Chi guarda?" (crea o scegli).
        if profiles.active == nil {
            ProfilesView(required: true)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        ServerLibraryDrawerHost {
            tabView
        }
        // Esc / ⌘L su Mac, tasti da tastiera su iPad: apri e chiudi la Libreria.
        .background {
            Button("Libreria") {
                let drawer = ServerLibraryDrawer.shared
                drawer.isOpen ? drawer.close() : drawer.open()
            }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var sections: some View {
        #if EXTRA_POSTERS
        TabView {
            Tab("Recenti", systemImage: "clock.arrow.circlepath") {
                LibraryHomeView()
            }
        }
        #else
        // Versione pubblica: una sola schermata, niente schede (né la
        // barra in basso su iPhone né il selettore in alto su Mac).
        LibraryHomeView()
        #endif
    }

    private var tabView: some View {
        sections
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
        // Minutaggio del profilo: all'avvio e ogni volta che si torna
        // nell'app (magari dopo aver guardato qualcosa su un altro dispositivo).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ProfileSync.shared.sync() }
        }
        .task {
            ProfileSync.shared.observeLibraryChanges()
            ProfileSync.shared.sync()
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
