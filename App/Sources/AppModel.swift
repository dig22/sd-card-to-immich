import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle, running, finished(String), failed(String)
    }

    @Published var settings = AppSettings.load()
    @Published var hasKey = Keychain.exists()
    @Published var cards: [CardInfo] = []
    /// Removable volumes macOS won't let us read yet (permission denied).
    @Published var blockedVolumes: [String] = []
    @Published var selected: CardInfo.ID?
    @Published var scanning = false
    @Published var phase: Phase = .idle
    @Published var fraction: Double = 0
    @Published var detail = ""
    @Published var log: [String] = []
    @Published var statuses: [URL: FileStatus] = [:]
    @Published var showLog = false
    @Published var showSettings = false
    /// Shown before the first Keychain read of an app version (macOS will ask once).
    @Published var keychainNotice: (() -> Void)?

    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private static let noticeKey = "keychainNoticeShownForVersion"
    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    var isConfigured: Bool { !settings.normalizedServer.isEmpty && hasKey }
    var isRunning: Bool { phase == .running }
    var selectedCard: CardInfo? { cards.first { $0.id == selected } ?? cards.first }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(bringToFront: name == NSWorkspace.didMountNotification) }
            })
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !isConfigured { showSettings = true }
        Task { await refresh(bringToFront: false) }
    }

    func refresh(bringToFront: Bool) async {
        scanning = true
        let before = Set(cards.map(\.id))
        let (videos, rawOnly) = (settings.videos, settings.rawOnly)
        let results = await Task.detached { CardScanner.scan(videos: videos, rawOnly: rawOnly) }.value
        cards = results.compactMap { if case .card(let c) = $0 { return c } else { return nil } }
        blockedVolumes = results.compactMap { if case .noAccess(let n) = $0 { return n } else { return nil } }
        if selected == nil || !cards.contains(where: { $0.id == selected }) { selected = cards.first?.id }
        if !isRunning { statuses = statuses.filter { url, _ in cards.contains { $0.files.contains { $0.url == url } } } }
        scanning = false
        Log.write("ui: showing \(cards.count) card(s) [\(cards.map(\.name).joined(separator: ", "))], configured=\(isConfigured)")
        if bringToFront, let new = cards.first(where: { !before.contains($0.id) }) {
            selected = new.id
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Reads the API key, first explaining the one-time macOS prompt after an app update.
    func withKey(_ body: @escaping (String) -> Void) {
        let read = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.appVersion, forKey: Self.noticeKey)
            if let k = Keychain.read() {
                body(k)
            } else {
                self.hasKey = Keychain.exists()
                self.phase = .failed("Couldn't read the API key from the Keychain. Enter it again in Settings.")
            }
        }
        if UserDefaults.standard.string(forKey: Self.noticeKey) == appVersion {
            read()
        } else {
            keychainNotice = read  // the view explains first, then calls this
        }
    }

    func start(dryRun: Bool) {
        guard let card = selectedCard else { return }
        withKey { key in self.run(card: card, key: key, dryRun: dryRun) }
    }

    private func run(card: CardInfo, key: String, dryRun: Bool) {
        log = []
        statuses = [:]
        fraction = 0
        detail = "Reading \(card.name)…"
        phase = .running
        let settings = self.settings
        let events = ImportEvents(
            log: { line in Task { @MainActor in self.append(line) } },
            phase: { text, f in Task { @MainActor in self.detail = text; self.fraction = f } },
            status: { url, st in Task { @MainActor in self.statuses[url] = st } })
        task = Task {
            do {
                let msg = try await Importer.run(card: card, settings: settings, key: key, dryRun: dryRun, events: events)
                fraction = 1
                phase = .finished(msg)
                append(msg)
                if !dryRun { notify("Import finished", msg) }
            } catch is CancellationError {
                phase = .failed("Cancelled.")
            } catch {
                phase = .failed(error.localizedDescription)
                append("Error: \(error.localizedDescription)")
                if !dryRun { notify("Import failed", error.localizedDescription) }
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func testConnection(server: String, key: String) async -> (ok: Bool, message: String) {
        do {
            let user = try await ImmichClient(server: server, key: key).me()
            return (true, "Connected as \(user)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    func reveal(_ card: CardInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: card.path)])
    }

    func eject(_ card: CardInfo) {
        try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: card.path))
    }
}
