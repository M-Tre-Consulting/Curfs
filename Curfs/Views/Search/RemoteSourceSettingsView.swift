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
    @State private var showLegal = false

    /// Analisi della sigla sul server: orario e stato (vedi ServerIntroIndex).
    @State private var introSettings: ServerIntroIndex.Settings?
    @State private var introSettingsLoaded: ServerIntroIndex.Settings?
    @State private var introServerStatus: ServerIntroIndex.Status?
    @State private var introLoadFailed = false
    @State private var introSaveFailed = false
    @State private var introRunState: TestState = .idle

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

                if RemoteSourceStore.current.baseURL != nil {
                    serverIntroSection
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

                // Firma M-Tre in fondo alle impostazioni (vedi Branding): nella
                // Libreria stava in un safeAreaInset e il contenuto ci scorreva sotto.
                Section {
                    NavigationLink {
                        legalPage
                    } label: {
                        Label("Privacy, licenza e contatti", systemImage: "info.circle")
                    }
                } footer: {
                    BrandFooter { showLegal = true }
                        .padding(.top, 12)
                }
            }
            #if os(macOS)
            // Su Mac il foglio prendeva la larghezza minima del contenuto e le
            // etichette dei campi ("Indirizzo del server") finivano a filo del
            // bordo: stile a riquadri con i suoi margini e una larghezza vera.
            .formStyle(.grouped)
            .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 680)
            #endif
            .navigationDestination(isPresented: $showLegal) { legalPage }
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

    // MARK: - Sigla sul server

    @ViewBuilder
    private var serverIntroSection: some View {
        Section {
            if let settings = introSettings {
                Toggle("Analisi notturna", isOn: Binding(
                    get: { settings.nightly },
                    set: { introSettings?.nightly = $0 }))
                DatePicker("Orario", selection: Binding(
                    get: { Self.date(from: settings.time) },
                    set: { introSettings?.time = Self.time(from: $0) }),
                    displayedComponents: .hourAndMinute)
                    .disabled(!settings.nightly)
                if introSaveFailed {
                    Label("Non sono riuscito a salvare sul server", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } else if introLoadFailed {
                Label("Server non raggiungibile", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                ProgressView()
            }

            if let status = introServerStatus {
                if status.running {
                    Label(status.current.map { String(localized: "In corso: \(($0 as NSString).lastPathComponent)") } ?? String(localized: "In corso"),
                          systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let last = status.lastNightly {
                    Text("Ultima analisi: \(Date(timeIntervalSince1970: last).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                runServerIntroNow()
            } label: {
                HStack {
                    Text("Analizza ora le novità")
                    Spacer()
                    switch introRunState {
                    case .testing: ProgressView()
                    case .ok: Label("Inviato", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor).font(.caption)
                    case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption).lineLimit(2)
                    case .idle: EmptyView()
                    }
                }
            }
            .disabled(introRunState == .testing || introServerStatus?.running == true)
        } header: {
            Text("Sigla sul server")
        } footer: {
            Text("Il server cerca sigla e titoli di coda degli episodi nuovi o cambiati una volta al giorno, all'orario scelto (ora del server), e li condivide con tutti i dispositivi e la TV. Dalla scheda di una serie puoi farlo partire subito per una stagione.")
        }
        .task { await loadServerIntro() }
        .task(id: introSettings) {
            // Salva da solo, poco dopo l'ultima modifica (la rotella dell'orario
            // cambia valore di continuo mentre gira).
            guard let settings = introSettings, settings != introSettingsLoaded else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            do {
                try await ServerIntroIndex.shared.save(settings)
                introSettingsLoaded = settings
                introSaveFailed = false
            } catch {
                introSaveFailed = true
            }
        }
    }

    private func loadServerIntro() async {
        async let settings = ServerIntroIndex.shared.settings()
        async let status = ServerIntroIndex.shared.status()
        let (s, st) = await (settings, status)
        introServerStatus = st
        if let s {
            introSettingsLoaded = s
            introSettings = s
        } else {
            introLoadFailed = true
        }
    }

    private func runServerIntroNow() {
        introRunState = .testing
        Task {
            do {
                try await ServerIntroIndex.shared.requestFullAnalysis()
                introRunState = .ok(0)
            } catch {
                introRunState = .failed(String(localized: "Server non raggiungibile"))
            }
        }
    }

    private static func date(from time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = parts.first ?? 0
        c.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: c) ?? .now
    }

    private static func time(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private var legalPage: some View {
        LegalView()
            .navigationTitle("Privacy, licenza e contatti")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
