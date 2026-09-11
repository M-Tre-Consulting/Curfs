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

struct RemoteSourceSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLString: String
    @State private var username: String
    @State private var password: String

    @State private var testState: TestState = .idle

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
                    TextField("https://nome-pi.tuo-tailnet.ts.net", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.callout.monospaced())
                } header: {
                    Text("Indirizzo del server")
                } footer: {
                    Text("L'URL servito da «tailscale serve» sul tuo Raspberry Pi. Deve rispondere con l'elenco delle cartelle in JSON (nginx: autoindex_format json).")
                }

                Section {
                    TextField("Nome utente", text: $username)
                        .textInputAutocapitalization(.never)
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
            }
            .navigationTitle("Fonte remota")
            .navigationBarTitleDisplayMode(.inline)
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
            Label("\(count) elementi", systemImage: "checkmark.circle.fill")
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
}

#Preview {
    RemoteSourceSettingsView()
        .preferredColorScheme(.dark)
}
