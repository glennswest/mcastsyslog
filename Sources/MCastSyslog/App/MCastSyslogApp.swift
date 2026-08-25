import SwiftUI

@main
struct MCastSyslogApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var model: StreamModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: StreamModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 760)
        .commands { commands }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Open an Event Bundle…") {
                NotificationCenter.default.post(name: .mcastImportBundle, object: nil)
            }
            .keyboardShortcut("o")

            Divider()

            Button("Export as Event Bundle…") {
                NotificationCenter.default.post(name: .mcastExportJSONL, object: nil)
            }
            .keyboardShortcut("e")

            Button("Export as JSON Document…") {
                NotificationCenter.default.post(name: .mcastExportJSON, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Export as Plain Text…") {
                NotificationCenter.default.post(name: .mcastExportText, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }

        CommandMenu("Stream") {
            Button(model.receiver.isListening ? "Stop Listening" : "Start Listening") {
                model.toggleListening()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Toggle("Follow the Live Tail", isOn: Binding(
                get: { model.isFollowing }, set: { model.isFollowing = $0 }))
                .keyboardShortcut("t")

            Divider()

            Button("Jump to a Moment…") {
                NotificationCenter.default.post(name: .mcastJumpToMoment, object: nil)
            }
            .keyboardShortcut("j")

            Button("Find in Messages") {
                NotificationCenter.default.post(name: .mcastFocusSearch, object: nil)
            }
            .keyboardShortcut("f")

            Divider()

            Button("Clear Filters") { model.filter = FilterState() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!model.filter.isActive)

            Button("All Nodes") { model.focus(host: nil) }
                .keyboardShortcut("0", modifiers: [.command, .shift])

            Divider()

            // Deliberately without a keyboard shortcut. A menu shortcut fires
            // app-wide, including while a text field has focus, and this is the
            // one action in the app that cannot be undone.
            Button("Clear Stored Events…") {
                NotificationCenter.default.post(name: .mcastClearLog, object: nil)
            }
            .disabled(model.storeStats.events == 0)
        }
    }
}
