//
//  RemoteContentProvider.swift
//  Curfs
//
//  Contratto astratto per la sezione Search: qui dentro NON c'è collegata
//  nessuna fonte, né legale né illegale. Per usarla davvero:
//
//   1. Scrivi un tipo che implementa RemoteContentProvider parlando con il
//      tuo server (URL, endpoint, autenticazione: i dettagli veri del TUO
//      protocollo, di cui questo file non sa nulla).
//   2. Sostituisci RemoteContentProviderRegistry.shared con un'istanza di
//      quel tipo. Nessun'altra view va toccata: Search, la scheda titolo e i
//      download parlano solo con questo protocollo.
//

import Foundation

enum RemoteTitleKind: String, Codable, Sendable {
    case movie
    case series
}

/// Un risultato di ricerca remoto, prima ancora di sapere come scaricarlo.
struct RemoteTitle: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var kind: RemoteTitleKind
    var year: String?
    var posterURL: URL?
    var overview: String?
    /// Dove caricare una copertina scelta dall'utente (file accanto al
    /// contenuto sul server). `nil` se la fonte non supporta copertine proprie.
    var customPosterUploadURL: URL? = nil
    /// `posterURL` punta a una copertina caricata dall'utente (non a iTunes).
    var hasCustomPoster: Bool = false
}

struct RemoteEpisode: Identifiable, Sendable, Hashable {
    var id: String
    var number: Int
    var title: String?
}

struct RemoteSeason: Identifiable, Sendable, Hashable {
    var number: Int
    var episodes: [RemoteEpisode]
    var id: Int { number }
}

/// Il risultato della risoluzione di un download: un URL scaricabile
/// direttamente con una GET. Tutto il lavoro di autenticazione/risoluzione
/// dello stream è responsabilità del provider concreto, non di questo layer.
struct RemoteDownloadTarget: Sendable {
    var fileURL: URL
    var suggestedFileExtension: String
}

/// URL diretto da dare in pasto ad `AVPlayer` per lo streaming, con gli
/// header (es. `Authorization`) che il player deve mandare a ogni richiesta
/// Range. Se il file è progressivo (mp4/mov) e il server supporta le
/// richieste Range, non serve scaricarlo prima di guardarlo.
struct RemoteStreamTarget: Sendable {
    var url: URL
    var headers: [String: String]
}

enum RemoteProviderError: LocalizedError {
    case notConfigured
    case unauthorized
    case badListing
    case server(status: Int)
    case uploadNotSupported
    case unreachable(host: String)

    /// Traduce gli errori di rete di URLSession in `unreachable`, così chi
    /// usa l'app capisce cosa fare invece di leggere "errore SSL".
    /// Tipico con Tailscale spento: il nome `*.ts.net` si risolve comunque
    /// col DNS pubblico ai server di Tailscale, che chiudono l'handshake TLS
    /// (non è la firma dell'app né il certificato del Pi).
    static func mapped(_ error: Error, host: String?) -> Error {
        guard let urlError = error as? URLError, let host else { return error }
        switch urlError.code {
        case .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return RemoteProviderError.unreachable(host: host)
        default:
            return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Nessuna fonte remota configurata. Apri le impostazioni della sezione Cerca e inserisci l'indirizzo del tuo server.")
        case .unauthorized:
            return String(localized: "Accesso negato: controlla nome utente e password del server.")
        case .badListing:
            return String(localized: "Il server ha risposto, ma non con un elenco di cartelle in JSON (serve nginx con «autoindex_format json»).")
        case .server(let status):
            return String(localized: "Il server ha risposto con un errore (HTTP \(status)).")
        case .uploadNotSupported:
            return String(localized: "Il server non accetta il caricamento di copertine: va abilitato PUT/DELETE (WebDAV) su nginx per i file poster.")
        case .unreachable(let host):
            if host.hasSuffix(".ts.net") {
                return String(localized: "Server \(host) non raggiungibile: controlla che Tailscale sia acceso e connesso su questo dispositivo.")
            }
            return String(localized: "Server \(host) non raggiungibile: controlla la connessione e l'indirizzo del server.")
        }
    }
}

protocol RemoteContentProvider: Sendable {
    /// Cerca titoli (film e/o serie) per nome.
    func search(query: String) async throws -> [RemoteTitle]

    /// Elenco stagioni/episodi di una serie. Non richiesto per i film.
    func seasons(for title: RemoteTitle) async throws -> [RemoteSeason]

    /// Risolve l'URL diretto (+ header) per riprodurre in streaming un film
    /// (episode: nil) o un episodio specifico di una serie.
    func streamTarget(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteStreamTarget

    /// Risolve l'URL diretto del file da scaricare per un film (episode: nil)
    /// o per un episodio specifico di una serie.
    func resolveDownload(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteDownloadTarget

    /// Salva sul server una copertina scelta dall'utente (JPEG già
    /// ritagliato 2:3) accanto al contenuto del titolo. Restituisce il nuovo
    /// `posterURL` da mostrare.
    func setCustomPoster(_ jpegData: Data, for title: RemoteTitle) async throws -> URL

    /// Rimuove la copertina dell'utente: si torna a quella di iTunes (se c'è).
    func removeCustomPoster(for title: RemoteTitle) async throws -> URL?
}

/// Provider "vuoto" usato finché non colleghi una fonte vera: la sezione
/// Search resta pienamente funzionante nell'interfaccia, ma ogni richiesta
/// fallisce in modo esplicito con RemoteProviderError.notConfigured invece
/// di mostrare dati finti.
struct UnconfiguredRemoteProvider: RemoteContentProvider {
    func search(query: String) async throws -> [RemoteTitle] {
        throw RemoteProviderError.notConfigured
    }

    func seasons(for title: RemoteTitle) async throws -> [RemoteSeason] {
        throw RemoteProviderError.notConfigured
    }

    func streamTarget(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteStreamTarget {
        throw RemoteProviderError.notConfigured
    }

    func resolveDownload(for title: RemoteTitle, episode: RemoteEpisode?) async throws -> RemoteDownloadTarget {
        throw RemoteProviderError.notConfigured
    }

    func setCustomPoster(_ jpegData: Data, for title: RemoteTitle) async throws -> URL {
        throw RemoteProviderError.notConfigured
    }

    func removeCustomPoster(for title: RemoteTitle) async throws -> URL? {
        throw RemoteProviderError.notConfigured
    }
}

enum RemoteContentProviderRegistry {
    /// Costruisce il provider dalla configurazione salvata (indirizzo del
    /// server + credenziali). Finché non è stato inserito un indirizzo
    /// valido restituisce il provider "vuoto": la sezione Cerca resta
    /// navigabile ma ogni richiesta fallisce in modo esplicito.
    static func makeProvider(config: RemoteSourceConfig = RemoteSourceStore.current) -> RemoteContentProvider {
        guard config.isConfigured else { return UnconfiguredRemoteProvider() }
        return HTTPTreeProvider(config: config)
    }
}
