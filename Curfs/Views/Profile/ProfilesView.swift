//
//  ProfilesView.swift
//  Curfs
//
//  Scheda dei profili (dal tasto in alto nella Libreria): la riga delle foto
//  (`ProfileSwitcher`, tocca un altro profilo per passarci: le foto si
//  scambiano di posto), il profilo attivo e "Nuovo profilo". Con
//  `required` è la schermata "Chi guarda?" che RootTabView mostra al posto
//  dell'app finché non si entra in un profilo: senza profilo Curfs non si
//  usa (scelta dell'utente), e non c'è un "esci". Profili e
//  minutaggio stanno sul server (vedi ProfileSync); qui niente `Menu`, per
//  il problema dei menu bloccati su Mac (vedi CLAUDE.md).
//

import SwiftUI

struct ProfilesView: View {
    /// Schermata obbligatoria all'avvio: niente "Fine", si esce solo entrando.
    var required = false

    @Environment(\.dismiss) private var dismiss
    @State private var sync = ProfileSync.shared

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var actionError: String?
    /// Il profilo mostrato come attivo: cambia subito al tocco (animazione),
    /// mentre il cambio vero (sincronizzazione) finisce in background.
    @State private var shownActiveID: String? = ProfileSync.shared.active?.id
    @State private var swap: ProfileSwap?
    @State private var isSwitching = false
    @State private var isConfigured = RemoteSourceStore.current.isConfigured
    @State private var showServerSettings = false

    private var shownActive: UserProfile? {
        sync.profiles.first { $0.id == shownActiveID } ?? (sync.active?.id == shownActiveID ? sync.active : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isConfigured {
                    Section {
                        Label("I profili stanno sul tuo server: inserisci prima il suo indirizzo.", systemImage: "server.rack")
                            .foregroundStyle(.secondary)
                        Button("Imposta il server…") { showServerSettings = true }
                    }
                } else {
                    profilesSection
                    if let active = sync.active, active.id == shownActiveID {
                        activeSection(active)
                    }
                    Section {
                        NavigationLink {
                            ProfileEditorView(profile: nil)
                        } label: {
                            Label("Nuovo profilo", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("Il profilo salva sul tuo server a che punto sei di ogni episodio e film, così iPhone, Mac e TV riprendono dallo stesso punto. I download restano su ciascun dispositivo.")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
            #endif
            .navigationTitle(required ? String(localized: "Chi guarda?") : String(localized: "Profili"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !required {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showServerSettings) {
                RemoteSourceSettingsView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSourceConfigChanged)) { _ in
                isConfigured = RemoteSourceStore.current.isConfigured
                Task { await reload() }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .alert("Profili", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(actionError ?? "")
            }
            .onChange(of: sync.active?.id) { _, id in
                // Cambiato altrove (profilo cancellato, primo accesso).
                if !isSwitching, id != shownActiveID {
                    withAnimation(ProfileSwitcher.animation) { shownActiveID = id }
                }
            }
        }
    }

    private func activeSection(_ active: UserProfile) -> some View {
        Section {
            Button {
                sync.sync()
            } label: {
                Label("Sincronizza ora", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isSyncing)

            NavigationLink {
                ProfileEditorView(profile: active)
            } label: {
                Label("Modifica profilo", systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if sync.isSyncing {
            Label("Sincronizzazione…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = sync.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        } else if let date = sync.lastSync {
            Label(String(localized: "Sincronizzato alle \(date.formatted(date: .omitted, time: .shortened))"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profilesSection: some View {
        Section {
            if isLoading && sync.profiles.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let loadError, sync.profiles.isEmpty {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if sync.profiles.isEmpty {
                Text("Ancora nessun profilo sul server.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ProfileSwitcher(profiles: sync.profiles, activeID: shownActiveID, swap: swap, onSelect: select)
                        .allowsHitTesting(!isSwitching)
                    if shownActive != nil {
                        if isSwitching {
                            Label("Cambio profilo…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            syncStatus
                        }
                    }
                }
            }
        } header: {
            Text(shownActiveID == nil ? "Entra in un profilo" : "Profilo attivo")
        } footer: {
            if shownActiveID == nil && !sync.profiles.isEmpty {
                Text("Entrando, il minutaggio già presente su questo dispositivo si unisce a quello del profilo.")
            } else if sync.profiles.count > 1 {
                Text("Tocca un altro profilo per passarci. Libreria e minutaggio del profilo di prima restano salvati sul server.")
            }
        }
    }

    private func reload() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await sync.refreshProfiles()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Lo scambio delle foto parte subito; se il cambio non riesce (server
    /// irraggiungibile) le foto tornano com'erano.
    private func select(_ profile: UserProfile) {
        let previous = shownActiveID
        withAnimation(ProfileSwitcher.animation) {
            swap = ProfileSwap(incoming: profile.id, outgoing: previous)
            shownActiveID = profile.id
        }
        Task {
            isSwitching = true
            defer { isSwitching = false }
            do {
                try await sync.switchTo(profile)
            } catch {
                withAnimation(ProfileSwitcher.animation) {
                    swap = previous.map { ProfileSwap(incoming: $0, outgoing: profile.id) }
                    shownActiveID = previous
                }
                actionError = error.localizedDescription
            }
        }
    }
}
