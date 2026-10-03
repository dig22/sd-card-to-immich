import SwiftUI

@main
struct SDToImmichApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SD to Immich") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.cards, selection: $model.selected) { card in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name).font(.headline)
                        Text("\(card.totalItems) items · \(ByteCountFormatter.string(fromByteCount: card.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sdcard.fill").foregroundStyle(.tint)
                }
                .tag(card.id)
                .contextMenu {
                    Button("Show in Finder") { model.reveal(card) }
                    Button("Eject") { model.eject(card) }.disabled(model.isRunning)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .overlay {
                if model.cards.isEmpty {
                    Text("No card").foregroundStyle(.secondary)
                }
            }
        } detail: {
            if !model.isConfigured {
                SetupPrompt()
            } else if let card = model.selectedCard {
                CardDetail(card: card)
            } else if !model.blockedVolumes.isEmpty {
                NoAccess()
            } else {
                EmptyCard()
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh(bringToFront: false) }
                } label: { Label("Rescan cards", systemImage: "arrow.clockwise") }
                .disabled(model.isRunning)
            }
            ToolbarItem {
                Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
    }
}

struct EmptyCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sdcard").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Insert a camera SD card").font(.title2)
            Text("Cards with a DCIM folder appear here automatically.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoAccess: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.orange)
            Text("SD to Immich can't read “\(model.blockedVolumes.joined(separator: "”, “"))”").font(.title2)
                .multilineTextAlignment(.center)
            Text("Allow access in System Settings → Privacy & Security → Files and Folders → SD to Immich → Removable Volumes, then rescan.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Open Privacy Settings") { model.openPrivacySettings() }.controlSize(.large)
                Button("Rescan") { Task { await model.refresh(bringToFront: false) } }.controlSize(.large)
            }
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
            Text("Add your Immich address and an API key to start importing.")
                .foregroundStyle(.secondary)
            Button("Open Settings") { model.showSettings = true }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CardDetail: View {
    @EnvironmentObject var model: AppModel
    let card: CardInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label(card.name, systemImage: "sdcard.fill").font(.largeTitle.bold())
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: card.bytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Stat(value: card.raw, label: "RAW photos", symbol: "camera.aperture")
                Stat(value: card.jpg, label: "JPG without RAW", symbol: "photo")
                Stat(value: model.settings.videos ? card.videos : 0,
                     label: model.settings.videos ? "Videos" : "Videos (off)", symbol: "video")
            }

            Text("RAW is uploaded for every shot; its JPG twin is skipped. Items already in Immich are skipped and still added to their day album (\(albumExample)).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.isRunning {
                    Button(role: .cancel) { model.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                        .controlSize(.large)
                } else {
                    Button { model.start(dryRun: false) } label: {
                        Label("Import to Immich", systemImage: "square.and.arrow.up").frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Button("Check what's new") { model.start(dryRun: true) }.controlSize(.large)
                }
                Spacer()
                Button("Eject") { model.eject(card) }.disabled(model.isRunning)
            }

            ProgressPanel()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var albumExample: String {
        let f = DateFormatter()
        f.dateFormat = strftimeToDateFormat(model.settings.albumFormat)
        return "e.g. “\(f.string(from: Date()))”"
    }
}

struct Stat: View {
    let value: Int
    let label: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text("\(value)").font(.title.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .scanning, .uploading:
                ProgressView(value: model.fraction) { Text(model.detail) }
            case .finished(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !model.log.isEmpty {
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
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings.load()
    @State private var key = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Immich server") {
                    TextField("Server URL", text: $draft.server, prompt: Text("https://immich.example.com"))
                    SecureField("API key", text: $key,
                                prompt: Text(model.hasKey ? "Saved in Keychain (type to replace)" : "Paste API key"))
                    Text("Create a key in Immich → Account Settings → API Keys with: user.read, asset.upload, album.read, album.create, albumAsset.create. It is stored in your macOS Keychain, never in a file.")
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
                    Toggle("RAW only (also skip JPGs that have no RAW)", isOn: $draft.rawOnly)
                    TextField("Album name format", text: $draft.albumFormat, prompt: Text("%Y-%m-%d"))
                    Text("strftime format of the capture date, e.g. %Y-%m-%d → 2026-10-02, %d %b %Y → 02 Oct 2026.")
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
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.normalizedServer.isEmpty || (key.isEmpty && !model.hasKey))
            }
            .padding()
        }
        .frame(width: 560, height: 600)
    }

    private func persist() -> Bool {
        draft.server = draft.normalizedServer
        if !key.isEmpty {
            guard Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                testResult = "Could not save the key to Keychain."
                testOK = false
                return false
            }
            key = ""
            model.hasKey = true
        }
        do {
            try draft.save()
            model.settings = draft
            Task { await model.refresh(bringToFront: false) }  // videos / RAW-only change the counts
            return true
        } catch {
            testResult = "Could not save settings: \(error.localizedDescription)"
            testOK = false
            return false
        }
    }

    private func test() {
        guard persist(), let k = Keychain.read() else { return }
        testing = true
        testResult = nil
        Task {
            do {
                let user = try await Engine.check(apiKey: k)
                testResult = "Connected as \(user)"
                testOK = true
            } catch {
                testResult = error.localizedDescription
                testOK = false
            }
            testing = false
        }
    }

    private func save() {
        if persist() { dismiss() }
    }
}

/// Minimal strftime -> DateFormatter mapping for the album-name preview.
func strftimeToDateFormat(_ s: String) -> String {
    let map: [Character: String] = ["Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "b": "MMM", "B": "MMMM",
                                    "a": "EEE", "A": "EEEE", "H": "HH", "M": "mm", "j": "DDD"]
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "%", s.index(after: i) < s.endIndex {
            let c = s[s.index(after: i)]
            out += map[c] ?? ""
            i = s.index(i, offsetBy: 2)
        } else {
            let ch = s[i]
            out += ch.isLetter ? "'\(ch)'" : String(ch)
            i = s.index(after: i)
        }
    }
    return out
}
