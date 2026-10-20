import AppKit
import Combine
import Security
import SwiftUI

/// Keeps the app up to date from the M-Tre site, the same way in every M-Tre Mac app (the
/// same file is in Macus, MarkIt and Curfs for Mac: change it in all of them).
///
/// `https://mtre-consulting.it/aggiornamenti/<slug>` tells the latest version, taken by the
/// site from the app's latest GitHub release (private repos included: the site holds the
/// token, the app none). When it's newer than this copy, a popup offers it:
/// - outside the sandbox (Macus), "Update and restart" downloads the DMG from `…/scarica`,
///   checks that the app inside has the same bundle id and is signed by the same team as
///   this one, puts it in place of this copy and opens it;
/// - in the sandbox (MarkIt, Curfs), which can't touch /Applications, it downloads the DMG,
///   opens it and quits, for the new app to be dragged over the old one.
///
/// A copy from the App Store never checks: the App Store updates it.
@MainActor
final class Updater: ObservableObject {
    struct Release: Decodable, Equatable {
        let version: String
        let publishedAt: String?
        let notes: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state = State.idle
    /// A check the user asked for has just found nothing new: say so for a moment.
    @Published private(set) var confirmsUpToDate = false

    /// The app's name on the site: `/aggiornamenti/<slug>`.
    let slug: String
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    /// The version the popup has already offered, so a later check doesn't offer it again.
    private var offered: String?

    /// The site, or another base for trying a local copy of it (`updateFeed` default).
    private static var base: URL {
        UserDefaults.standard.string(forKey: "updateFeed").flatMap(URL.init(string:))
            ?? URL(string: "https://mtre-consulting.it")!
    }

    /// Installed from the App Store, which updates the app itself.
    static var isFromAppStore: Bool {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receipt.path)
    }

    /// In the sandbox, the app can't replace itself.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    init(slug: String) {
        self.slug = slug
    }

    /// Checks now and then every few hours; a new version shows the popup.
    func start() {
        guard !Self.isFromAppStore else { return }
        Task { await check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    var newRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Asks the site for the latest version. Quietly leaves the state alone when the site
    /// can't be reached, unless the user asked.
    func check(userAsked: Bool = false) async {
        guard !Self.isFromAppStore else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        let before = state
        state = .checking
        do {
            let url = Self.base.appendingPathComponent("aggiornamenti/\(slug)")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("\(slug)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            if Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                if userAsked || offered != release.version { offer(release) }
            } else {
                state = .upToDate
                if userAsked { confirmUpToDate() }
            }
        } catch {
            state = userAsked ? .failed(error.localizedDescription) : before == .checking ? .idle : before
            if userAsked { showFailure(error.localizedDescription) }
        }
    }

    /// For a "Check for Updates…" menu item.
    func checkFromMenu() {
        Task { await check(userAsked: true) }
    }

    // MARK: - Popups

    private func offer(_ release: Release) {
        offered = release.version
        let alert = NSAlert()
        alert.messageText = String(localized: "\(appName) \(release.version) è disponibile")
        alert.informativeText = String(localized: "Hai la versione \(currentVersion).")
        alert.addButton(withTitle: Self.isSandboxed ? String(localized: "Scarica l'aggiornamento")
                                                    : String(localized: "Aggiorna e riavvia"))
        alert.addButton(withTitle: String(localized: "Più tardi"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    private func confirmUpToDate() {
        confirmsUpToDate = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            confirmsUpToDate = false
        }
        // Menu-bar apps show it in their own menu; windowed ones get a popup.
        guard NSApp.activationPolicy() == .regular else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Hai l'ultima versione")
        alert.informativeText = String(localized: "\(appName) \(currentVersion) è la versione più recente.")
        alert.runModal()
    }

    private func showFailure(_ message: String) {
        guard NSApp.activationPolicy() == .regular else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Aggiornamento non riuscito: \(message)")
        alert.runModal()
    }

    // MARK: - Installing

    /// Downloads the new version, then swaps it in and restarts, or in the sandbox opens it.
    func install() {
        guard let release = newRelease else { return }
        state = .downloading(0)
        let url = Self.base.appendingPathComponent("aggiornamenti/\(slug)/scarica")
        let name = "\(appName).dmg"
        let task = URLSession.shared.downloadTask(with: url) { [weak self] file, response, error in
            // The file is gone once this returns: keep it.
            var kept: URL?
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                if (try? FileManager.default.moveItem(at: file, to: target)) != nil { kept = target }
            }
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                guard let kept else {
                    self.fail(failure ?? String(localized: "Download non riuscito"))
                    return
                }
                if Self.isSandboxed {
                    self.handOver(kept, release: release)
                    return
                }
                self.state = .installing
                let result = await Task.detached { Self.installFrom(dmg: kept) }.value
                try? FileManager.default.removeItem(at: kept)
                if let message = result {
                    self.fail(message)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(fraction) }
            }
        }
        download = task
        task.resume()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        showFailure(message)
    }

    /// Sandbox: says what to do, then quits and opens the DMG in the Finder. The app must be
    /// closed before the new one is dragged over it: the Finder replacing a running app
    /// breaks it.
    private func handOver(_ dmg: URL, release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Trascina \(appName) nella cartella Applicazioni")
        alert.informativeText = String(localized: "Si apre il disco dell'aggiornamento e \(appName) si chiude. Trascina la nuova versione in Applicazioni, scegli Sostituisci e riaprila.")
        alert.addButton(withTitle: String(localized: "Apri l'aggiornamento"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
            state = .available(release)
            return
        }
        state = .installing
        NSWorkspace.shared.open(dmg)
        NSApp.terminate(nil)
    }

    /// Mounts the DMG, checks the app in it and hands the swap to a small script that runs
    /// once this app has quit. Returns an error message, or nil when the app should quit.
    nonisolated private static func installFrom(dmg: URL) -> String? {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("update-mount-\(UUID().uuidString)")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mount.path]) == 0 else {
            return String(localized: "Impossibile aprire l'aggiornamento")
        }
        defer { run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let current = Bundle.main.bundleURL
        guard let found = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let new = Bundle(url: found), new.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return String(localized: "L'aggiornamento non contiene questa app")
        }
        // Only an app signed by whoever signed this one may take its place.
        guard let team = teamIdentifier(of: current), teamIdentifier(of: found) == team,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", found.path]) == 0 else {
            return String(localized: "La firma dell'aggiornamento non corrisponde")
        }

        // Copied next to the app first, so the swap itself is a rename on the same disk.
        let staged = current.deletingLastPathComponent().appendingPathComponent(".\(current.lastPathComponent).update")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [found.path, staged.path]) == 0 else {
            return String(localized: "Non posso scrivere nella cartella dell'app")
        }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Waits for this app to quit, swaps the copies and opens the new one.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        old="$1.old"
        rm -rf "$old"
        mv "$1" "$old" || exit 1
        if mv "$2" "$1"; then rm -rf "$old"; else mv "$old" "$1"; fi
        open "$1"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "swap", current.path, staged.path]
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        do { try swap.run() } catch { return error.localizedDescription }
        return nil
    }

    nonisolated private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// "1.10.0" is newer than "1.9.2": compared number by number.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The update row of an app's settings: shows up when there's something to say.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .available(let release):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aggiornamento disponibile").font(.headline)
                    Text("Versione \(release.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(Updater.isSandboxed ? "Scarica l'aggiornamento" : "Aggiorna e riavvia") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Scarico l'aggiornamento…").font(.caption) }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installo l'aggiornamento…").font(.caption)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Aggiornamento non riuscito: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Riprova") { updater.checkFromMenu() }
                    .controlSize(.small)
            }
        default:
            if updater.confirmsUpToDate {
                Label("Hai l'ultima versione", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small button that checks for updates now.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button {
            updater.checkFromMenu()
        } label: {
            if updater.state == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .help(Text("Controlla aggiornamenti"))
        .disabled(Updater.isFromAppStore)
    }
}
