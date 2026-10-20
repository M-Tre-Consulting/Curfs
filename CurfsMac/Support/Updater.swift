import AppKit

/// Tells when there's a new version and sends to the App Store to get it. The same file is in
/// MarkIt and Curfs for Mac: change it in both. (Macus, sold from the site and never on the
/// store, keeps its own updater.)
///
/// `https://mtre-consulting.it/aggiornamenti/<slug>` tells the latest version, taken by the
/// site from the app's latest GitHub release. When it's newer than this copy, a popup offers
/// to open the app's App Store page. Until the app is on the store (`appStore` nil), the
/// button opens its page on the M-Tre site instead.
///
/// A copy from the App Store never checks: the App Store updates it.
@MainActor
final class Updater {
    private struct Release: Decodable {
        let version: String
    }

    /// The app's name on the site: `/aggiornamenti/<slug>`.
    let slug: String
    /// Where the button sends: the App Store page, or the site while the app isn't there yet.
    let page: URL
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
    private var timer: Timer?
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

    init(slug: String, appStore: URL?, site: URL) {
        self.slug = slug
        self.page = appStore ?? site
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

    /// For a "Check for Updates…" menu item.
    func checkFromMenu() {
        Task { await check(userAsked: true) }
    }

    /// Asks the site for the latest version. Quiet when the site can't be reached, unless
    /// the user asked.
    private func check(userAsked: Bool = false) async {
        do {
            let url = Self.base.appendingPathComponent("aggiornamenti/\(slug)")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("\(slug)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let version = try JSONDecoder().decode(Release.self, from: data).version
            if Self.isNewer(version, than: currentVersion) {
                if userAsked || offered != version { offer(version) }
            } else if userAsked {
                show(String(localized: "Hai l'ultima versione"),
                     String(localized: "\(appName) \(currentVersion) è la versione più recente."))
            }
        } catch {
            if userAsked { show(String(localized: "Impossibile controllare gli aggiornamenti"), error.localizedDescription) }
        }
    }

    private func offer(_ version: String) {
        offered = version
        let alert = NSAlert()
        alert.messageText = String(localized: "\(appName) \(version) è disponibile")
        alert.informativeText = String(localized: "Hai la versione \(currentVersion).")
        alert.addButton(withTitle: String(localized: "Apri l'App Store"))
        alert.addButton(withTitle: String(localized: "Più tardi"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
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
