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
    /// "1.2 GB left · ~4 min · 6.3 MB/s" while an import runs.
    @Published var transferInfo = ""
    /// After an import or check: whether the card can be formatted (everything is in Immich).
    @Published var safeToFormat: Verdict?
    @Published var showLog = false
    @Published var showSettings = false
    /// Shown before the first Keychain read of an app version (macOS will ask once).
    @Published var keychainNotice: (() -> Void)?

    struct Verdict: Equatable {
        let safe: Bool
        let message: String
    }

    /// Pending "Free up space" deletion, waiting for the user's confirmation.
    @Published var freePlan: (card: CardInfo, plan: FreeSpace.Plan, kept: Int)?

    /// The API key after the first Keychain read of this launch: macOS is asked at most once.
    var cachedKey: String?
    private var task: Task<Void, Never>?
    private var samples: [(time: Date, bytes: Int64)] = []
    private var observers: [NSObjectProtocol] = []
    private static let noticeKey = "keychainNoticeShownForVersion"
    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    var isConfigured: Bool { !settings.normalizedServer.isEmpty && hasKey }
    var isRunning: Bool { phase == .running }
    var selectedCard: CardInfo? { cards.first { $0.id == selected } ?? cards.first }

    /// `preview: true` builds a model with no side effects (no volume scan, no
    /// notification permission) for screenshots and SwiftUI previews.
    init(preview: Bool = false) {
        if preview { return }
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
            if settings.autoImport && isConfigured && !isRunning && !new.files.isEmpty {
                Log.write("auto-import: \(new.name)")
                start(dryRun: false)
            }
        }
    }

    /// Reads the API key, first explaining the one-time macOS prompt after an app update.
    func withKey(_ body: @escaping (String) -> Void) {
        if let k = cachedKey { return body(k) }
        let read = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.appVersion, forKey: Self.noticeKey)
            if let k = Keychain.read() {
                self.cachedKey = k
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
        samples = []
        transferInfo = ""
        safeToFormat = nil
        detail = "Reading \(card.name)…"
        phase = .running
        let settings = self.settings
        let events = ImportEvents(
            log: { line in Task { @MainActor in self.append(line) } },
            phase: { text, f in Task { @MainActor in self.detail = text; self.fraction = f } },
            status: { url, st in Task { @MainActor in self.statuses[url] = st } },
            bytes: { done, total in Task { @MainActor in self.updateTransfer(done: done, total: total) } })
        task = Task {
            do {
                let outcome = try await Importer.run(card: card, settings: settings, key: key, dryRun: dryRun, events: events)
                let msg = outcome.message
                statuses.merge(outcome.statuses) { _, exact in exact }
                fraction = 1
                transferInfo = ""
                phase = .finished(msg)
                append(msg)
                let verdict = Self.verdict(card: card, statuses: statuses)
                safeToFormat = verdict
                Log.write("\(dryRun ? "check" : "import") \(card.name): \(msg) | \(verdict.message)")
                if !dryRun {
                    notify("Import finished", verdict.safe ? "\(msg) \(verdict.message)" : msg)
                    if settings.ejectWhenDone && !statuses.values.contains(.failed) {
                        eject(card)
                        append("Ejected \(card.name).")
                        Log.write("ejected \(card.name)")
                    }
                }
            } catch is CancellationError {
                phase = .failed("Cancelled.")
            } catch {
                phase = .failed(error.localizedDescription)
                append("Error: \(error.localizedDescription)")
                Log.write("import \(card.name) failed: \(error.localizedDescription)")
                if !dryRun { notify("Import failed", error.localizedDescription) }
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Step 1 of "Free up space": verify every file on the card with Immich, then ask.
    func prepareFreeSpace() {
        guard let card = selectedCard else { return }
        Log.write("free space \(card.name): verifying \(card.files.count) file(s)")
        withKey { key in
            self.log = []
            self.safeToFormat = nil
            self.phase = .running
            self.fraction = 0
            self.transferInfo = ""
            self.detail = "Checking what on \(card.name) is safely in Immich…"
            let settings = self.settings
            self.task = Task {
                do {
                    let client = try ImmichClient(server: settings.normalizedServer, key: key)
                    let (verified, trashed) = try await FreeSpace.verify(card.files, client: client)
                    for f in card.files {
                        self.statuses[f.url] = verified.contains(f.url) ? .inImmich : trashed.contains(f.url) ? .trashed : .new
                    }
                    let plan = FreeSpace.plan(card: card, verified: verified)
                    let kept = card.files.count - verified.count
                    Log.write("free space \(card.name): \(verified.count) verified, \(trashed.count) only in trash, plan \(plan.delete.count) file(s) / \(plan.bytes) bytes, keep \(kept)")
                    self.fraction = 1
                    if plan.delete.isEmpty {
                        self.phase = .finished(trashed.isEmpty
                            ? "Nothing on \(card.name) is in Immich yet, so nothing can be removed."
                            : "Nothing removed: \(trashed.count) item\(trashed.count == 1 ? " is" : "s are") only in Immich's trash. Restore \(trashed.count == 1 ? "it" : "them") in Immich first.")
                    } else {
                        self.phase = .idle
                        self.freePlan = (card, plan, kept)
                    }
                } catch {
                    self.phase = .failed(error.localizedDescription)
                    Log.write("free space \(card.name) failed: \(error.localizedDescription)")
                }
                self.task = nil
            }
        }
    }

    /// Step 2: the user confirmed. Deletes exactly the planned files.
    func confirmFreeSpace() {
        guard let pending = freePlan else { return }
        freePlan = nil
        let r = FreeSpace.execute(pending.plan)
        let freed = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
        var msg = "Freed \(freed) on \(pending.card.name): deleted \(r.deleted) file\(r.deleted == 1 ? "" : "s") that are in Immich."
        if pending.kept > 0 { msg += " Kept \(pending.kept) that are not in Immich." }
        if !r.failed.isEmpty { msg += " Could not delete: \(r.failed.prefix(5).joined(separator: ", "))." }
        phase = r.failed.isEmpty ? .finished(msg) : .failed(msg)
        append(msg)
        Log.write("free space \(pending.card.name): deleted \(r.deleted), \(r.bytes) bytes, kept \(pending.kept), failed \(r.failed.count)")
        notify("Space freed", msg)
        Task { await refresh(bringToFront: false) }
    }

    /// The card is safe to format when every file the import covers is confirmed in Immich
    /// (or deliberately skipped: a JPEG whose RAW is in Immich, a duplicate on the card), and
    /// the settings didn't leave anything out.
    nonisolated static func verdict(card: CardInfo, statuses: [URL: FileStatus]) -> Verdict {
        let inTrash = card.files.filter { statuses[$0.url] == .trashed }.count
        let notBackedUp = card.files.filter { f in
            switch statuses[f.url] ?? .pending {
            case .inImmich, .skipped, .trashed: return false
            default: return true
            }
        }.count
        if inTrash > 0 {
            return Verdict(safe: false, message: "\(inTrash) item\(inTrash == 1 ? " matches a photo" : "s match photos") in Immich's trash, which is emptied after 30 days. Restore \(inTrash == 1 ? "it" : "them") in Immich before formatting \(card.name).")
        }
        var excluded: [String] = []
        if card.excludedVideos > 0 { excluded.append("\(card.excludedVideos) video\(card.excludedVideos == 1 ? "" : "s") (Import videos is off)") }
        if card.excludedJPG > 0 { excluded.append("\(card.excludedJPG) JPEG-only photo\(card.excludedJPG == 1 ? "" : "s") (RAW only is on)") }
        if notBackedUp > 0 {
            return Verdict(safe: false, message: "\(notBackedUp) item\(notBackedUp == 1 ? " is" : "s are") not in Immich yet. Don't format \(card.name).")
        }
        if !excluded.isEmpty {
            return Verdict(safe: false, message: "Everything imported is in Immich, but \(excluded.joined(separator: " and ")) on \(card.name) were not imported. Don't format it yet.")
        }
        let what = card.files.count == 1 ? "The only item" : "All \(card.files.count) items"
        let verb = card.files.count == 1 ? "is" : "are"
        return Verdict(safe: true, message: "\(what) on \(card.name) \(verb) in Immich. It's safe to format the card in your camera.")
    }

    private func updateTransfer(done: Int64, total: Int64) {
        let now = Date()
        samples.append((now, done))
        samples.removeAll { now.timeIntervalSince($0.time) > 15 }
        transferInfo = Self.transferText(done: done, total: total, samples: samples, now: now)
    }

    /// "1.2 GB left · ~4 min · 6.3 MB/s" from the bytes processed in the last 15 s.
    nonisolated static func transferText(done: Int64, total: Int64, samples: [(time: Date, bytes: Int64)], now: Date) -> String {
        let left = max(0, total - done)
        var parts = ["\(ByteCountFormatter.string(fromByteCount: left, countStyle: .file)) left"]
        if let first = samples.first, now.timeIntervalSince(first.time) >= 2 {
            let rate = Double(done - first.bytes) / now.timeIntervalSince(first.time)
            if rate > 0 {
                let secs = Double(left) / rate
                let eta = secs < 60 ? "less than a minute" : secs < 3600 ? "~\(Int((secs / 60).rounded())) min"
                    : String(format: "~%dh %02dm", Int(secs) / 3600, (Int(secs) % 3600) / 60)
                parts.append(eta)
                parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s")
            }
        }
        return parts.joined(separator: " · ")
    }

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
