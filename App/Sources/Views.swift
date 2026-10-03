import ServiceManagement
import SwiftUI

/// Single pane: connection status, the cards, actions, progress. No collapsible sidebar,
/// so a detected card is always visible.
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if !model.isConfigured {
                SetupPrompt()
            } else if model.cards.isEmpty {
                if model.blockedVolumes.isEmpty { EmptyCard() } else { NoAccess() }
            } else {
                CardList()
                if let card = model.selectedCard {
                    Actions(card: card)
                    ProgressPanel()
                    StatusLegend(card: card)
                    ThumbnailGrid(card: card)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .alert("Allow access to your Immich key", isPresented: Binding(
            get: { model.keychainNotice != nil }, set: { if !$0 { model.keychainNotice = nil } })) {
            Button("Continue") {
                let go = model.keychainNotice
                model.keychainNotice = nil
                go?()
            }
            Button("Cancel", role: .cancel) { model.keychainNotice = nil }
        } message: {
            Text("Your Immich API key is stored encrypted in the macOS Keychain. After installing or updating SD to Immich, macOS asks once whether the app may read it. Click “Always Allow” so it doesn't ask again for this version.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard.fill").font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("SD to Immich").font(.title2.bold())
                Text(model.isConfigured ? model.settings.normalizedServer : "Not connected to Immich yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.scanning { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh(bringToFront: false) } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRunning || model.scanning)
            Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct CardList: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.cards) { card in
                let selected = model.selectedCard?.id == card.id
                Button { model.selected = card.id } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sdcard.fill").font(.system(size: 30)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.name).font(.headline)
                            Text(summary(card)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: card.bytes, countStyle: .file))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .contextMenu {
                    Button("Show in Finder") { model.reveal(card) }
                    Button("Eject") { model.eject(card) }.disabled(model.isRunning)
                }
            }
        }
    }

    private func summary(_ c: CardInfo) -> String {
        var bits = ["\(c.raw) RAW"]
        if c.jpg > 0 { bits.append("\(c.jpg) JPG without RAW") }
        if c.videos > 0 { bits.append("\(c.videos) videos") }
        return bits.joined(separator: " · ")
    }
}

struct Actions: View {
    @EnvironmentObject var model: AppModel
    let card: CardInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RAW is uploaded for every shot and its JPEG twin is skipped. Anything already in Immich is skipped and still added to its day album (e.g. “\(model.settings.albumName(for: Date()))”).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isRunning {
                    Button(role: .cancel) { model.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                        .controlSize(.large)
                } else {
                    Button { model.start(dryRun: false) } label: {
                        Label("Import to Immich", systemImage: "square.and.arrow.up").frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    Button("Check what's new") { model.start(dryRun: true) }.controlSize(.large)
                }
                Spacer()
                Button("Eject \(card.name)") { model.eject(card) }.disabled(model.isRunning)
            }
        }
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .running:
                ProgressView(value: model.fraction) { Text(model.detail).lineLimit(1) } currentValueLabel: {
                    if !model.transferInfo.isEmpty { Text(model.transferInfo).monospacedDigit() }
                }
                .tint(.accentColor)  // stays blue when the window is in the background
            case .finished(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            if let v = model.safeToFormat, !model.isRunning {
                Label(v.message, systemImage: v.safe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(v.safe ? Color.green : Color.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((v.safe ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if !model.log.isEmpty {
                DisclosureGroup("Details", isExpanded: $model.showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: model.log.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                .frame(height: 120)
                }
                .font(.caption)
            }
        }
    }
}

struct EmptyCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sdcard").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Insert a camera SD card").font(.title2)
            Text("Cards with a DCIM folder appear here automatically.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoAccess: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.orange)
            Text("Can't read “\(model.blockedVolumes.joined(separator: "”, “"))”").font(.title2)
            Text("Allow SD to Immich in System Settings → Privacy & Security → Files and Folders → Removable Volumes, then click Rescan.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                Button("Rescan") { Task { await model.refresh(bringToFront: false) } }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SetupPrompt: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Connect to your Immich server").font(.title2)
            Text("Add your Immich address and an API key to start importing.").foregroundStyle(.secondary)
            Button("Open Settings") { model.showSettings = true }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings
    @State private var key = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    init(draft: AppSettings = AppSettings.load()) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Immich server") {
                    TextField("Server URL", text: $draft.server, prompt: Text("https://immich.example.com"))
                    SecureField("API key", text: $key,
                                prompt: Text(model.hasKey ? "Saved in Keychain (type to replace)" : "Paste API key"))
                    Text("Create a key in Immich → Account Settings → API Keys with: user.read, asset.upload, album.read, album.create, albumAsset.create. It is stored encrypted in your macOS Keychain, never in a file.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(testing ? "Testing…" : "Test connection") { test() }
                            .disabled(testing || draft.normalizedServer.isEmpty || (key.isEmpty && !model.hasKey))
                        if let testResult {
                            Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(testOK ? .green : .red).lineLimit(2)
                        }
                    }
                }
                Section("Import") {
                    Toggle("Import videos", isOn: $draft.videos)
                    Toggle("RAW only (also skip JPEGs that have no RAW)", isOn: $draft.rawOnly)
                    TextField("Album name format", text: $draft.albumFormat, prompt: Text("%Y-%m-%d"))
                    Text("Capture date in strftime format. Today: “\(draft.albumName(for: Date()))”. Try %d %b %Y.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Automation") {
                    Toggle("Import automatically when a card is inserted", isOn: $draft.autoImport)
                    Toggle("Eject the card when the import is done", isOn: $draft.ejectWhenDone)
                    Toggle("Open SD to Immich at login", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { on in setOpenAtLogin(on) }
                    if let loginNote {
                        Text(loginNote).font(.caption).foregroundStyle(.orange)
                    }
                    Text("With both of the first two on: insert a card and walk away. You get a notification, and the card is ejected once everything is in Immich.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Large files (optional)") {
                    TextField("Relay SSH host", text: $draft.relayHost, prompt: Text("user@host near Immich"))
                    Stepper("Use relay for files over \(draft.relayMinMB) MB", value: $draft.relayMinMB, in: 50...5000, step: 50)
                    Text("Immich drops uploads that take more than ~5 minutes. On a slow link, big videos are copied with rsync (resumable) to this host and uploaded from there. Needs key-based SSH, rsync and curl on the host.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if model.hasKey {
                    Button("Remove API key", role: .destructive) {
                        Keychain.delete()
                        model.hasKey = false
                        model.cachedKey = nil
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if persist() { dismiss() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.normalizedServer.isEmpty || (key.isEmpty && !model.hasKey))
            }
            .padding()
        }
        .frame(width: 560, height: 680)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = SMAppService.mainApp.status == .requiresApproval
                ? "Approve SD to Immich in System Settings → General → Login Items." : nil
        } catch {
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func persist() -> Bool {
        draft.server = draft.normalizedServer
        if !key.isEmpty {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Keychain.save(trimmed) else {
                (testResult, testOK) = ("Could not save the key to the Keychain.", false)
                return false
            }
            key = ""
            model.hasKey = true
            model.cachedKey = trimmed  // just saved: no need to read it back
        }
        do {
            try draft.save()
            model.settings = draft
            Task { await model.refresh(bringToFront: false) }  // videos / RAW-only change the counts
            return true
        } catch {
            (testResult, testOK) = ("Could not save settings: \(error.localizedDescription)", false)
            return false
        }
    }

    private func test() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard persist() else { return }
        let server = draft.normalizedServer
        testing = true
        testResult = nil
        let go: (String) -> Void = { k in
            Task {
                let r = await model.testConnection(server: server, key: k)
                (testResult, testOK, testing) = (r.message, r.ok, false)
            }
        }
        if !typed.isEmpty { go(typed) } else { model.withKey(go) }
    }
}
