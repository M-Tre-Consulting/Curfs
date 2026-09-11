//
//  RemoteDownloadManager.swift
//  Curfs
//
//  Download offline degli episodi/film dal server remoto (il Pi). A
//  differenza dello streaming — che è `AVPlayer` che legge l'URL con
//  richieste Range — qui si scarica l'INTERO file, identico a quello sul
//  server, e lo si porta in libreria come item locale (stessa struttura di
//  cartelle di ImportEngine: Movies/ oppure Shows/<serie>/Stagione N/).
//
//  Il trasferimento usa una `URLSession` di BACKGROUND: prosegue mentre
//  l'app è sospesa e — se serve — fa rilanciare l'app dal sistema per la
//  finalizzazione. Ogni download è tracciato in un registro su disco
//  (`records.json`) così sopravvive alla chiusura dell'app, e in caso di
//  interruzione riparte da dove era rimasto tramite `resumeData` invece che
//  da zero. Vedi `BackgroundDownloadEngine`.
//

import Foundation
import SwiftData
@preconcurrency import AVFoundation

// MARK: - Modello richiesta / stato per la UI

struct RemoteDownloadRequest: Sendable {
    var title: String
    var kind: MediaKind
    var showName: String?
    var season: Int?
    var episode: Int?
}

enum RemoteDownloadState: Equatable, Sendable {
    case downloading(progress: Double)
    /// Interrotto (app chiusa, rete caduta): c'è `resumeData` su disco, la
    /// ripresa è automatica al rientro o manuale dal pannello.
    case paused(progress: Double)
    case finalizing
    case completed
    case failed(String)
}

struct RemoteDownloadItem: Identifiable, Sendable {
    let id: UUID
    var label: String
    var state: RemoteDownloadState
}

// MARK: - Facciata @MainActor osservata dalla UI

@MainActor
@Observable
final class RemoteDownloadManager {
    /// Unica istanza: la `URLSession` di background è legata a un identificatore
    /// e deve esistere per tutta la vita del processo (anche fuori dalla tab
    /// Cerca), per ricevere gli eventi di completamento dopo un rilancio.
    static let shared = RemoteDownloadManager()

    private(set) var items: [RemoteDownloadItem] = []
    private let engine = BackgroundDownloadEngine()

    private init() {
        engine.setOnChange { [weak self] snapshot in
            Task { @MainActor in self?.items = snapshot }
        }
        engine.emitNow()
    }

    var hasActiveDownloads: Bool {
        items.contains { item in
            switch item.state {
            case .completed, .failed: return false
            case .downloading, .paused, .finalizing: return true
            }
        }
    }

    @discardableResult
    func start(target: RemoteDownloadTarget, request: RemoteDownloadRequest) -> UUID {
        let id = UUID()
        engine.enqueue(
            id: id,
            url: target.fileURL,
            fileExtension: target.suggestedFileExtension,
            request: request
        )
        return id
    }

    func cancel(id: UUID) { engine.cancel(id: id) }
    func retry(id: UUID) { engine.retry(id: id) }
    func dismiss(id: UUID) { engine.forget(id: id) }

    /// Chiamata dall'`AppDelegate` quando iOS risveglia l'app per consegnare
    /// gli eventi della sessione di background: memorizza il completion handler
    /// di sistema, che va invocato appena finito di processarli.
    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloadEngine.sessionIdentifier else {
            completionHandler()
            return
        }
        engine.setBackgroundCompletionHandler(completionHandler)
    }
}

// MARK: - Motore: URLSession di background + registro persistito

final class BackgroundDownloadEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.nicoloperri.Mediapple.downloads"

    /// Tutto lo stato mutabile (registro, task vivi, handler, callback UI) è
    /// serializzato qui: i callback di URLSession arrivano su una coda di
    /// sistema.
    private let stateQueue = DispatchQueue(label: "curfs.downloads.state")

    /// Notifica alla UI lo snapshot corrente. Impostata via `setOnChange`,
    /// letta solo su `stateQueue`, invocata sulla coda main.
    private var onChange: (@Sendable ([RemoteDownloadItem]) -> Void)?
    private var records: [UUID: DownloadRecord] = [:]
    private var order: [UUID] = []
    private var liveTasks: [UUID: URLSessionTask] = [:]
    private var autoResumeAttempts: [UUID: Int] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private var lastPersist = Date.distantPast

    private static let maxAutoResumeAttempts = 4

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.sessionSendsLaunchEvents = true       // rilancia l'app a trasferimento finito
        cfg.isDiscretionary = false               // parti subito, non "quando conviene"
        cfg.allowsCellularAccess = true
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        stateQueue.async {
            self.records = Self.loadRecords()
            self.order = self.records.values
                .sorted { $0.createdAt < $1.createdAt }
                .map(\.id)
        }
        // Forza la creazione della sessione: registra il delegate così gli
        // eventi in sospeso da un trasferimento concluso mentre l'app era
        // chiusa vengono consegnati.
        _ = session
        reconcile()
    }

    // MARK: Comandi dalla facciata

    func enqueue(id: UUID, url: URL, fileExtension: String, request: RemoteDownloadRequest) {
        stateQueue.async {
            var record = DownloadRecord(
                id: id,
                sourceURL: url,
                fileExtension: fileExtension,
                title: request.title,
                kind: request.kind.rawValue,
                showName: request.showName,
                season: request.season,
                episode: request.episode,
                totalBytes: 0,
                receivedBytes: 0,
                status: .downloading,
                errorMessage: nil,
                createdAt: Date()
            )
            self.records[id] = record
            self.order.append(id)
            self.startTask(for: &record, resumeIfPossible: false)
            self.records[id] = record
            self.persist(force: true)
            self.emit()
        }
    }

    func retry(id: UUID) {
        stateQueue.async {
            guard var record = self.records[id] else { return }
            self.autoResumeAttempts[id] = 0
            record.status = .downloading
            record.errorMessage = nil
            self.startTask(for: &record, resumeIfPossible: true)
            self.records[id] = record
            self.persist(force: true)
            self.emit()
        }
    }

    func cancel(id: UUID) {
        stateQueue.async {
            self.liveTasks[id]?.cancel()
            self.liveTasks[id] = nil
            self.cleanupFiles(for: id)
            self.records[id] = nil
            self.order.removeAll { $0 == id }
            self.autoResumeAttempts[id] = nil
            self.persist(force: true)
            self.emit()
        }
    }

    /// Come `cancel`, ma pensata per togliere dalla lista una riga già
    /// completata o fallita (nessun task da fermare).
    func forget(id: UUID) { cancel(id: id) }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        stateQueue.async { self.backgroundCompletionHandler = handler }
    }

    func setOnChange(_ handler: @escaping @Sendable ([RemoteDownloadItem]) -> Void) {
        stateQueue.async { self.onChange = handler }
    }

    func emitNow() {
        stateQueue.async { self.emit() }
    }

    // MARK: Riconciliazione all'avvio

    /// All'avvio confronta il registro su disco con i task realmente vivi
    /// nella sessione di background: quelli spariti (app terminata) vengono
    /// messi in pausa e ripresi; una finalizzazione lasciata a metà viene
    /// ritentata se il file in staging è ancora lì.
    private func reconcile() {
        session.getAllTasks { tasks in
            self.stateQueue.async {
                let liveByID = Dictionary(uniqueKeysWithValues: tasks.compactMap { task -> (UUID, URLSessionTask)? in
                    guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return nil }
                    return (id, task)
                })
                self.liveTasks = liveByID

                for id in self.order {
                    guard var record = self.records[id] else { continue }
                    if liveByID[id] != nil {
                        record.status = .downloading
                        self.records[id] = record
                        continue
                    }
                    switch record.status {
                    case .completed, .failed:
                        break
                    case .finalizing:
                        let staging = Self.stagingURL(id)
                        if FileManager.default.fileExists(atPath: staging.path) {
                            self.finalize(id: id, staging: staging, record: record)
                        } else {
                            record.status = .failed
                            record.errorMessage = "Interrotto durante il salvataggio"
                            self.records[id] = record
                        }
                    case .downloading, .paused:
                        record.status = .paused
                        self.records[id] = record
                        self.startTask(for: &record, resumeIfPossible: true)
                        self.records[id] = record
                    }
                }
                self.persist(force: true)
                self.emit()
            }
        }
    }

    // MARK: Creazione task (nuovo o da resumeData) — sempre su stateQueue

    private func startTask(for record: inout DownloadRecord, resumeIfPossible: Bool) {
        let id = record.id
        liveTasks[id]?.cancel()

        let task: URLSessionDownloadTask
        let resumeURL = Self.resumeURL(id)
        if resumeIfPossible, let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: record.sourceURL)
            for (field, value) in RemoteSourceStore.current.authHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
            task = session.downloadTask(with: request)
        }
        try? FileManager.default.removeItem(at: resumeURL)
        task.taskDescription = id.uuidString
        liveTasks[id] = task
        record.status = .downloading
        task.resume()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init) else { return }
        stateQueue.async {
            guard var record = self.records[id] else { return }
            record.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { record.totalBytes = totalBytesExpectedToWrite }
            record.status = .downloading
            self.records[id] = record
            self.persist(force: false)
            self.emit()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init) else { return }

        // Il file a `location` viene rimosso dal sistema appena questo metodo
        // ritorna: va spostato ORA, in modo sincrono.
        let staging = Self.stagingURL(id)
        try? FileManager.default.removeItem(at: staging)
        var moveError: String?
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: staging)
            } catch {
                moveError = error.localizedDescription
            }
        }

        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let httpOK = statusCode.map { (200...299).contains($0) } ?? true

        stateQueue.async {
            self.liveTasks[id] = nil
            guard var record = self.records[id] else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            if let moveError {
                record.status = .failed
                record.errorMessage = moveError
                self.records[id] = record
                self.persist(force: true); self.emit()
                return
            }
            if !httpOK {
                record.status = .failed
                record.errorMessage = "Risposta del server: \(statusCode ?? -1)"
                self.records[id] = record
                try? FileManager.default.removeItem(at: staging)
                self.persist(force: true); self.emit()
                return
            }
            record.status = .finalizing
            record.receivedBytes = record.totalBytes
            self.records[id] = record
            self.persist(force: true); self.emit()
            self.finalize(id: id, staging: staging, record: record)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init) else { return }
        stateQueue.async {
            self.liveTasks[id] = nil
            guard let error else { return }   // il successo passa da didFinishDownloadingTo
            guard var record = self.records[id],
                  record.status != .completed, record.status != .finalizing else { return }

            let nsError = error as NSError
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: Self.resumeURL(id), options: .atomic)
                record.status = .paused
                record.errorMessage = nil
            } else if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                // annullato dall'utente senza resumeData: la riga è già stata
                // rimossa da cancel(); qui non resta nulla da fare.
                return
            } else {
                record.status = .paused
                record.errorMessage = error.localizedDescription
            }
            self.records[id] = record
            self.persist(force: true)
            self.emit()
            self.scheduleAutoResume(id: id)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            DispatchQueue.main.async { handler?() }
        }
    }

    // MARK: Ripresa automatica dopo un'interruzione

    private func scheduleAutoResume(id: UUID) {
        let attempts = autoResumeAttempts[id, default: 0]
        guard attempts < Self.maxAutoResumeAttempts else { return }
        autoResumeAttempts[id] = attempts + 1
        let delay = pow(2.0, Double(attempts))   // 1, 2, 4, 8 s
        stateQueue.asyncAfter(deadline: .now() + delay) {
            guard var record = self.records[id], record.status == .paused else { return }
            self.startTask(for: &record, resumeIfPossible: true)
            self.records[id] = record
            self.persist(force: true)
            self.emit()
        }
    }

    // MARK: Finalizzazione: staging → libreria + MediaItem

    private func finalize(id: UUID, staging: URL, record: DownloadRecord) {
        Task.detached(priority: .utility) {
            do {
                let kind = MediaKind(rawValue: record.kind) ?? .movie
                let request = RemoteDownloadRequest(
                    title: record.title, kind: kind, showName: record.showName,
                    season: record.season, episode: record.episode
                )
                let relativePath = try Self.moveIntoLibrary(
                    stagingURL: staging,
                    fileExtension: record.fileExtension,
                    request: request
                )
                let destURL = LibraryStorage.mediaDirectory.appending(path: relativePath)
                let seconds = await MediaDurationMeasurer.measure(at: destURL)

                let context = ModelContext(AppModelContainer.shared)
                let media = MediaItem(
                    title: request.title,
                    kind: kind,
                    showName: request.showName,
                    seasonNumber: request.season,
                    episodeNumber: request.episode,
                    relativePath: relativePath,
                    duration: seconds
                )
                context.insert(media)
                try context.save()
                await ThumbnailGenerator.generateIfNeeded(for: media)

                self.stateQueue.async {
                    guard var done = self.records[id] else { return }
                    done.status = .completed
                    done.receivedBytes = done.totalBytes
                    self.records[id] = done
                    try? FileManager.default.removeItem(at: Self.resumeURL(id))
                    self.persist(force: true)
                    self.emit()
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                self.stateQueue.async {
                    guard var failed = self.records[id] else { return }
                    failed.status = .failed
                    failed.errorMessage = error.localizedDescription
                    self.records[id] = failed
                    self.persist(force: true)
                    self.emit()
                }
            }
        }
    }

    /// Sposta il file scaricato nella struttura di cartelle della libreria,
    /// identica a quella di ImportEngine. Ritorna il path relativo a
    /// `LibraryStorage.mediaDirectory`.
    private static func moveIntoLibrary(stagingURL: URL,
                                        fileExtension: String,
                                        request: RemoteDownloadRequest) throws -> String {
        let fm = FileManager.default
        let safeBase = FileNameParser.sanitizeFilename(request.title)

        let subpath: [String]
        switch request.kind {
        case .movie:
            subpath = ["Movies"]
        case .episode:
            let show = FileNameParser.sanitizeFilename(request.showName ?? "Serie")
            let seasonName = String(format: "Stagione %d", request.season ?? 1)
            subpath = ["Shows", show, seasonName]
        }

        let destDir = subpath.reduce(LibraryStorage.mediaDirectory) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var destURL = destDir.appending(path: "\(safeBase).\(fileExtension)")
        var n = 1
        while fm.fileExists(atPath: destURL.path) {
            destURL = destDir.appending(path: "\(safeBase) (\(n)).\(fileExtension)")
            n += 1
        }
        try fm.moveItem(at: stagingURL, to: destURL)

        let fullPath = destURL.path
        let basePath = LibraryStorage.mediaDirectory.path
        if fullPath.hasPrefix(basePath) {
            return String(fullPath.dropFirst(basePath.count + 1))
        }
        return destURL.lastPathComponent
    }

    // MARK: Snapshot per la UI (su stateQueue)

    private func emit() {
        let snapshot: [RemoteDownloadItem] = order.compactMap { id in
            guard let record = records[id] else { return nil }
            let label = record.showName.map { "\($0) · \(record.title)" } ?? record.title
            return RemoteDownloadItem(id: id, label: label, state: record.uiState)
        }
        let onChange = self.onChange
        DispatchQueue.main.async { onChange?(snapshot) }
    }

    // MARK: Persistenza del registro

    private func persist(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) > 2 else { return }
        lastPersist = now
        let list = order.compactMap { records[$0] }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: Self.recordsURL, options: .atomic)
    }

    private static func loadRecords() -> [UUID: DownloadRecord] {
        guard let data = try? Data(contentsOf: recordsURL),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func cleanupFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: Self.resumeURL(id))
        try? FileManager.default.removeItem(at: Self.stagingURL(id))
    }

    // MARK: Percorsi su disco

    private static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var stagingDir: URL {
        let url = supportDir.appending(path: "staging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var recordsURL: URL { supportDir.appending(path: "records.json") }
    private static func resumeURL(_ id: UUID) -> URL { supportDir.appending(path: "\(id.uuidString).resume") }
    private static func stagingURL(_ id: UUID) -> URL { stagingDir.appending(path: id.uuidString) }
}

// MARK: - Record persistito

private struct DownloadRecord: Codable {
    let id: UUID
    var sourceURL: URL
    var fileExtension: String
    var title: String
    var kind: String
    var showName: String?
    var season: Int?
    var episode: Int?
    var totalBytes: Int64
    var receivedBytes: Int64
    var status: Status
    var errorMessage: String?
    var createdAt: Date

    enum Status: String, Codable {
        case downloading, paused, finalizing, completed, failed
    }

    var progress: Double {
        totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0
    }

    var uiState: RemoteDownloadState {
        switch status {
        case .downloading: return .downloading(progress: progress)
        case .paused: return .paused(progress: progress)
        case .finalizing: return .finalizing
        case .completed: return .completed
        case .failed: return .failed(errorMessage ?? "Errore")
        }
    }
}
