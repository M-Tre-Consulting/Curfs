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

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Nessuna fonte remota configurata. Aprila dalle impostazioni della sezione Cerca e inserisci l'indirizzo del tuo server."
        case .unauthorized:
            return "Accesso negato: controlla nome utente e password del server."
        case .badListing:
            return "Il server ha risposto, ma non con un elenco di cartelle in JSON (serve nginx con «autoindex_format json»)."
        case .server(let status):
            return "Il server ha risposto con un errore (HTTP \(status))."
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
