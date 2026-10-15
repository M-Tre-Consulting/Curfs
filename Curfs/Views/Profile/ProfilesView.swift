//
//  ProfilesView.swift
//  Curfs
//
//  Scheda dei profili (dal tasto in alto nella Libreria): il profilo attivo,
//  quelli salvati sul server per entrarci, e "Nuovo profilo". Con
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
    @State private var isWorking = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var pendingSwitch: UserProfile?
    @State private var isConfigured = RemoteSourceStore.current.isConfigured
    @State private var showServerSettings = false

    private var others: [UserProfile] { sync.profiles.filter { $0.id != sync.active?.id } }

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
                    if let active = sync.active {
                        activeSection(active)
                    }
                    profilesSection
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
            .disabled(isWorking)
            .overlay {
                if isWorking { ProgressView().controlSize(.large) }
            }
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
            .confirmationDialog(
                "Entrare nel profilo \"\(pendingSwitch?.name ?? "")\"?",
                isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
                titleVisibility: .visible
            ) {
                Button("Entra") {
                    if let profile = pendingSwitch { switchTo(profile) }
                    pendingSwitch = nil
                }
                Button("Annulla", role: .cancel) { pendingSwitch = nil }
            } message: {
                Text("Su questo dispositivo vedrai il minutaggio di \"\(pendingSwitch?.name ?? "")\". Quello di \"\(sync.active?.name ?? "")\" resta salvato sul server.")
            }
        }
    }

    private func activeSection(_ active: UserProfile) -> some View {
        Section {
            HStack(spacing: 14) {
                ProfileAvatar(profile: active, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(active.name)
                        .font(.title3.weight(.semibold))
                    syncStatus
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

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
        } header: {
            Text("Profilo attivo")
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
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if others.isEmpty {
                Text(sync.active == nil ? "Ancora nessun profilo sul server." : "Nessun altro profilo sul server.")
                    .foregroundStyle(.secondary)
            }
            ForEach(others) { profile in
                Button {
                    if sync.active == nil { switchTo(profile) } else { pendingSwitch = profile }
                } label: {
                    HStack(spacing: 12) {
                        ProfileAvatar(profile: profile, size: 36)
                        Text(profile.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(sync.active == nil ? "Entra in un profilo" : "Altri profili")
        } footer: {
            if sync.active == nil && !others.isEmpty {
                Text("Entrando, il minutaggio già presente su questo dispositivo si unisce a quello del profilo.")
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

    private func switchTo(_ profile: UserProfile) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await sync.switchTo(profile)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
