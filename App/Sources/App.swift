import SwiftUI

@main
struct SDToImmichApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SD to Immich") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Settings…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
