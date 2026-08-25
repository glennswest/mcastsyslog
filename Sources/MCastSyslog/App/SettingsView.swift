import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ListeningSettings()
                .tabItem { Label("Listening", systemImage: "antenna.radiowaves.left.and.right") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
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
