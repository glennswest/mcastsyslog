import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ListeningSettings()
                .tabItem { Label("Listening", systemImage: "antenna.radiowaves.left.and.right") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            APISettings()
                .tabItem { Label("REST API", systemImage: "curlybraces") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

struct ListeningSettings: View {
    @EnvironmentObject private var model: StreamModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Group or host", text: $settings.groupAddress)
                    .font(.system(size: 12, design: .monospaced))
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 90)
            } header: {
                Text("Where to listen")
            } footer: {
                Text(endpointNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start listening when the app opens", isOn: $settings.startListeningOnLaunch)
                HStack {
                    Button(model.receiver.isListening ? "Stop listening" : "Start listening") {
                        model.toggleListening()
                    }
                    Button("Rejoin now") { model.startListening() }
                        .help("Leave and re-join the group on every interface")
                    Button("Reset to default group") { settings.resetEndpoint() }
                    Spacer()
                }
            }

            Section("Interfaces") {
                if model.receiver.joined.isEmpty {
                    Text(model.receiver.isListening
                         ? "No interface has accepted a membership."
                         : "Not listening.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.receiver.joined) { iface in
                        HStack {
                            Image(systemName: iface.isLoopback ? "arrow.triangle.turn.up.right.circle" : "network")
                                .foregroundStyle(.secondary)
                            Text(iface.name).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(iface.address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.groupAddress) { restartIfListening() }
        .onChange(of: settings.port) { restartIfListening() }
    }

    private func restartIfListening() {
        guard model.receiver.isListening else { return }
        model.startListening()
    }

    private var endpointNote: String {
        if settings.endpoint.isMulticast {
            return "A multicast group is joined on every interface with an IPv4 address, and re-joined when the interface set changes. \(ListenEndpoint.default.description) is the default a node emits to."
        }
        return "This is not a multicast address, so there is no group to join — the socket is simply bound to it. A node overridden with stormpump.syslog=<host:port> to a unicast address is received exactly the same way."
    }
}

struct StorageSettings: View {
    @EnvironmentObject private var model: StreamModel
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.retentionGiB, in: 0.25...64) {
                            EmptyView()
                        }
                        Text(ByteCount.format(Int64(settings.retentionGiB * 1024 * 1024 * 1024)))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 74, alignment: .trailing)
                    }
                }
                LabeledContent("Age") {
                    HStack {
                        Stepper(value: $settings.retentionDays, in: 1...365) { EmptyView() }
                        Text("\(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            } header: {
                Text("Keep")
            } footer: {
                Text("Whichever comes first. Trimming deletes the oldest events as a whole time range and returns the space to the filesystem.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Now") {
                LabeledContent("Events", value: model.storeStats.events.formatted())
                LabeledContent("On disk", value: ByteCount.format(model.storeStats.bytes))
                LabeledContent("Nodes", value: "\(model.storeStats.hosts)")
                if let oldest = model.storeStats.oldestNanos {
                    LabeledContent("Oldest", value: Timestamp.format(oldest, style: .full))
                }
            }

            Section {
                LabeledContent("Live view holds") {
                    HStack {
                        Stepper(value: $settings.liveWindow, in: 500...50_000, step: 500) { EmptyView() }
                        Text("\(settings.liveWindow.formatted()) events")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            } footer: {
                Text("How many rows the table is willing to render. The store keeps far more; this only decides what is on screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Delete all stored events…", role: .destructive) { confirmClear = true }
                    Spacer()
                    Button("Reveal database in Finder") { revealDatabase() }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete every stored event?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { model.clearStore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The nodes keep their own files, and this viewer will fill up again from the group — but anything already recorded here is gone.")
        }
    }

    private func revealDatabase() {
        guard let path = try? EventStore.defaultPath() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The read-only HTTP API. Off by default, loopback by default — both because
/// this serves everything the viewer has heard from every node, and neither
/// should happen because nobody thought about it.
struct APISettings: View {
    @EnvironmentObject private var model: StreamModel
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmRemote = false

    var body: some View {
        Form {
            Section {
                Toggle("Serve the REST API", isOn: $settings.apiEnabled)
                LabeledContent("Port") {
                    TextField("", value: $settings.apiPort, format: .number.grouping(.never))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                }
                LabeledContent("Address") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.apiRunning ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray))
                            .frame(width: 7, height: 7)
                        if model.apiRunning {
                            Link(settings.apiBaseURL, destination: URL(string: settings.apiBaseURL)!)
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            Text(settings.apiBaseURL)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.apiError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .font(.callout)
                }
            } header: {
                Text("Serving")
            } footer: {
                Text("Read-only: only GET and HEAD are answered, and nothing the API can reach has a path back to a node.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reachable from other machines", isOn: Binding(
                    get: { settings.apiAllowRemote },
                    set: { on in
                        if on { confirmRemote = true } else { settings.apiAllowRemote = false }
                    }
                ))
            } footer: {
                Text(settings.apiAllowRemote
                     ? "Serving on every interface. Anything that can reach this Mac can read every line this viewer has heard from every node — there is no authentication."
                     : "Bound to 127.0.0.1. Nothing off this machine can reach it.")
                    .font(.callout)
                    .foregroundStyle(settings.apiAllowRemote ? Color(nsColor: .systemOrange) : .secondary)
            }

            Section("Try it") {
                ForEach(Self.examples, id: \.0) { example in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(example.0).font(.callout)
                        Text(example.1)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.apiEnabled) { model.restartAPI() }
        .onChange(of: settings.apiPort) { model.restartAPI() }
        .onChange(of: settings.apiAllowRemote) { model.restartAPI() }
        .confirmationDialog("Serve on every interface?", isPresented: $confirmRemote, titleVisibility: .visible) {
            Button("Serve on every interface", role: .destructive) { settings.apiAllowRemote = true }
            Button("Keep it on this Mac", role: .cancel) { settings.apiAllowRemote = false }
        } message: {
            Text("There is no authentication. Anything that can reach this Mac would be able to read every line this viewer has heard from every node in the fleet.")
        }
    }

    private static let examples: [(String, String)] = [
        ("Everything a node said in the last 15 minutes",
         "curl 'localhost:8514/api/v1/events?host=storm-01&last=15m'"),
        ("Errors and worse, across the fleet",
         "curl 'localhost:8514/api/v1/events?min_severity=error&limit=50'"),
        ("What surrounded a moment, on every node",
         "curl 'localhost:8514/api/v1/around?at=2026-08-24T21:47:11Z&window=30'"),
        ("A rollup of the last hour",
         "curl 'localhost:8514/api/v1/summary?last=1h'"),
        ("Follow the live tail",
         "curl -N 'localhost:8514/api/v1/stream?min_severity=warning'"),
    ]
}

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppVersion.name).font(.title2)
                    Text("\(AppVersion.summary)  ·  \(AppVersion.bundleVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("What this will never do")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Bullet("It never sends anything to a node. No acknowledgement, no back-pressure, no requests — a viewer that can ask a node for anything is a viewer that can slow a node down.")
                Bullet("It never writes to a node.")
                Bullet("It never drops a frame it could not parse. Those are kept verbatim and flagged, because a viewer that hides what it cannot parse hides exactly the interesting failures.")
            }
            .font(.callout)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
