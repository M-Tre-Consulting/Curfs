//
//  RemoteSourceSettingsView.swift
//  Curfs
//
//  Impostazioni della fonte remota: indirizzo del server (il Raspberry Pi
//  raggiunto via Tailscale) e credenziali basic-auth opzionali. Salvando si
//  emette `.remoteSourceConfigChanged`, che fa ricostruire il provider nella
//  tab Cerca.
//

import SwiftUI
import SwiftData

struct RemoteSourceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var baseURLString: String
    @State private var username: String
    @State private var password: String

    @State private var testState: TestState = .idle
    @State private var backfillState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case ok(Int)
        case failed(String)
    }

    init() {
        let config = RemoteSourceStore.current
        _baseURLString = State(initialValue: config.baseURLString)
        _username = State(initialValue: config.username)
        _password = State(initialValue: config.password)
    }

    private var draft: RemoteSourceConfig {
        RemoteSourceConfig(baseURLString: baseURLString, username: username, password: password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $baseURLString, prompt: Text(verbatim: "https://server.example.com")) { Text("Indirizzo del server") }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("Indirizzo del server")
                } footer: {
                    Text("L'indirizzo del tuo server di video, raggiungibile da questo dispositivo (per esempio in rete locale o via VPN). Deve rispondere con l'elenco delle cartelle in JSON (nginx: autoindex_format json) e supportare le richieste Range.")
                }

                Section {
                    TextField("Nome utente", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("Autenticazione")
                } footer: {
                    Text("Basic auth. Lascia vuoto se il server non la richiede.")
                }

                Section {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text("Prova connessione")
                            Spacer()
                            testStatusView
                        }
                    }
                    .disabled(draft.baseURL == nil || testState == .testing)
                }

                Section {
                    Button {
                        runBackfill()
                    } label: {
                        HStack {
                            Text("Ripara copertine scaricate")
                            Spacer()
                            backfillStatusView
                        }
                    }
                    .disabled(RemoteSourceStore.current.baseURL == nil || backfillState == .testing)
                } footer: {
                    Text("Per film ed episodi scaricati che mostrano un fotogramma del video invece della locandina: li confronta col catalogo del server e ripristina la locandina dove il nome corrisponde.")
                }
            }
            .navigationTitle("Fonte remota")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        RemoteSourceStore.current = draft
                        dismiss()
                    }
                    .disabled(!baseURLString.trimmingCharacters(in: .whitespaces).isEmpty && draft.baseURL == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .ok(let count):
            Label(String(localized: "\(count) elementi"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func runTest() {
        testState = .testing
        let provider = RemoteContentProviderRegistry.makeProvider(config: draft)
        Task {
            do {
                let results = try await provider.search(query: "")
                testState = .ok(results.count)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var backfillStatusView: some View {
        switch backfillState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .ok(let count):
            Label(count > 0 ? String(localized: "\(count) sistemati") : String(localized: "Nessuno da sistemare"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Usa la fonte già SALVATA (non la bozza in modifica): opera sulla
    /// libreria reale, non su un indirizzo che magari non hai ancora confermato.
    private func runBackfill() {
        backfillState = .testing
        let provider = RemoteContentProviderRegistry.makeProvider(config: RemoteSourceStore.current)
        Task {
            do {
                let catalog = try await provider.search(query: "")
                let fixed = LibraryMaintenance.backfillRemoteOrigin(catalog: catalog, modelContext: modelContext)
                backfillState = .ok(fixed)
            } catch {
                backfillState = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    RemoteSourceSettingsView()
        .preferredColorScheme(.dark)
}
