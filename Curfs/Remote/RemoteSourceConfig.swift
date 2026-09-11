//
//  RemoteSourceConfig.swift
//  Curfs
//
//  Configurazione della fonte remota (il server del Raspberry Pi raggiunto
//  via Tailscale): URL base + credenziali basic-auth opzionali. È l'unico
//  punto in cui l'app "sa" come raggiungere la libreria remota; da qui
//  HTTPTreeProvider costruisce le richieste.
//
//  Nota: le credenziali stanno in UserDefaults, non in Keychain. L'app è
//  personale, gira su un solo dispositivo e non va sull'App Store: la
//  semplicità qui vale più dell'irrobustimento.
//

import Foundation

struct RemoteSourceConfig: Equatable, Sendable {
    var baseURLString: String
    var username: String
    var password: String

    static let empty = RemoteSourceConfig(baseURLString: "", username: "", password: "")

    /// URL base normalizzato (senza slash finale, così i path relativi si
    /// concatenano in modo prevedibile).
    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let noTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: noTrailingSlash), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    var isConfigured: Bool { baseURL != nil }

    /// Header `Authorization: Basic ...` da usare sia per le richieste di
    /// elenco/ricerca sia come header dell'`AVURLAsset` in streaming. Vuoto
    /// se non sono state inserite credenziali.
    var authHeaders: [String: String] {
        guard !username.isEmpty || !password.isEmpty else { return [:] }
        let raw = "\(username):\(password)"
        guard let data = raw.data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic \(data.base64EncodedString())"]
    }
}

/// Lettura/scrittura persistente della configurazione. La scrittura emette
/// `.remoteSourceConfigChanged` così la tab Cerca può ricostruire il provider.
enum RemoteSourceStore {
    private static let defaults = UserDefaults.standard
    private static let keyBase = "Curfs.remote.baseURL"
    private static let keyUser = "Curfs.remote.username"
    private static let keyPass = "Curfs.remote.password"

    static var current: RemoteSourceConfig {
        get {
            RemoteSourceConfig(
                baseURLString: defaults.string(forKey: keyBase) ?? "",
                username: defaults.string(forKey: keyUser) ?? "",
                password: defaults.string(forKey: keyPass) ?? ""
            )
        }
        set {
            defaults.set(newValue.baseURLString, forKey: keyBase)
            defaults.set(newValue.username, forKey: keyUser)
            defaults.set(newValue.password, forKey: keyPass)
            NotificationCenter.default.post(name: .remoteSourceConfigChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let remoteSourceConfigChanged = Notification.Name("Curfs.remoteSourceConfigChanged")
}
