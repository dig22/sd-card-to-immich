import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, uploading, finished(String), failed(String)
    }

    @Published var settings = AppSettings.load()
    @Published var hasKey = Keychain.read() != nil
    @Published var cards: [CardInfo] = []
    /// Removable volumes macOS won't let us read yet (permission denied).
    @Published var blockedVolumes: [String] = []
    @Published var selected: CardInfo.ID?
    @Published var phase: Phase = .idle
    @Published var fraction: Double = 0
    @Published var detail = ""
    @Published var log: [String] = []
    @Published var showSettings = false

    private var process: Process?
    private var observers: [NSObjectProtocol] = []

    var isConfigured: Bool { !settings.normalizedServer.isEmpty && hasKey }
    var isRunning: Bool { phase == .scanning || phase == .uploading }
    var selectedCard: CardInfo? { cards.first { $0.id == selected } ?? cards.first }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    await self?.refresh(bringToFront: name == NSWorkspace.didMountNotification)
                }
            })
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !isConfigured { showSettings = true }
        Task { await refresh(bringToFront: false) }
    }

    func refresh(bringToFront: Bool) async {
        let before = Set(cards.map(\.id))
        let (videos, rawOnly) = (settings.videos, settings.rawOnly)
        let results = await Task.detached { CardScanner.scan(videos: videos, rawOnly: rawOnly) }.value
        cards = results.compactMap { if case .card(let c) = $0 { return c } else { return nil } }
        blockedVolumes = results.compactMap { if case .noAccess(let name, _) = $0 { return name } else { return nil } }
        if selected == nil || !cards.contains(where: { $0.id == selected }) {
            selected = cards.first?.id
        }
        // A newly inserted card: show it.
        if bringToFront, let new = cards.first(where: { !before.contains($0.id) }) {
            selected = new.id
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func start(dryRun: Bool) {
        guard let card = selectedCard, let key = Keychain.read() else { return }
        log = []
        fraction = 0
        detail = "Reading \(card.name)…"
        phase = .scanning
        var args = ["--card", card.path]
        if dryRun { args.append("--dry-run") }
        if !settings.videos { args.append("--no-videos") }
        if settings.rawOnly { args.append("--raw-only") }
        do {
            process = try Engine.startImport(args: args, apiKey: key, onEvent: { ev in
                Task { @MainActor in self.handle(ev) }
            }, onExit: { status in
                Task { @MainActor in self.finished(status: status, card: card, dryRun: dryRun) }
            })
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func handle(_ ev: EngineEvent) {
        if !ev.text.isEmpty && ev.type != "hashing" {
            log.append(contentsOf: ev.text.split(separator: "\n").map(String.init))
            if log.count > 500 { log.removeFirst(log.count - 500) }
        }
        switch ev.type {
        case "hashing":  // reading + checksumming the card: first 15 % of the bar
            if let n = ev.n, let t = ev.total, t > 0 {
                fraction = 0.15 * Double(n) / Double(t)
                detail = "Checking \(n) of \(t) files…"
            }
        case "plan":
            let new = ev.new ?? 0
            detail = new == 0 ? "Nothing new: everything is already in Immich."
                              : "\(new) new, \(ev.existing ?? 0) already in Immich"
            phase = .uploading
        case "progress":
            if let f = ev.fraction { fraction = 0.15 + 0.85 * f }
            if let n = ev.n, let t = ev.total { detail = "Uploading \(n) of \(t)…" }
        case "album":
            detail = "Updating albums…"
        case "done":
            phase = .finished(ev.text)
        case "error":
            phase = .failed(ev.text)
        default:
            break
        }
    }

    private func finished(status: Int32, card: CardInfo, dryRun: Bool) {
        process = nil
        switch phase {
        case .finished(let msg):
            fraction = 1
            if !dryRun { notify(title: "Import finished", body: msg) }
        case .failed(let msg):
            notify(title: "Import failed", body: msg)
        default:
            phase = status == 15 ? .failed("Cancelled.") : .failed("Stopped unexpectedly (exit \(status)). See the log.")
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: c, trigger: nil))
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
