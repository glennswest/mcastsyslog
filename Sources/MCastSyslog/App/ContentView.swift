import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: StreamModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showJump = false
    @State private var exportError: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FleetSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            HStack(spacing: 0) {
                EventStreamView()
                if model.showInspector {
                    Divider()
                    EventInspector()
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
            .navigationTitle(model.focusedHost ?? "All nodes")
            .navigationSubtitle(subtitle)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showJump) { JumpSheet().environmentObject(model) }
        .alert("Export failed", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcastJumpToMoment)) { _ in showJump = true }
        .onReceive(NotificationCenter.default.publisher(for: .mcastExportJSONL)) { _ in export(.jsonl) }
        .onReceive(NotificationCenter.default.publisher(for: .mcastExportText)) { _ in export(.text) }
        .onReceive(NotificationCenter.default.publisher(for: .mcastImportBundle)) { _ in importBundle() }
    }

    private var subtitle: String {
        let stored = model.storeStats.events
        guard stored > 0 else { return "nothing stored yet" }
        return "\(stored.formatted()) events stored across \(model.storeStats.hosts) node\(model.storeStats.hosts == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $model.isFollowing) {
                Label("Follow", systemImage: model.isFollowing ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button)
            .help(model.isFollowing
                  ? "Following the live tail. New events append as they arrive."
                  : "Paused. New events are counted, not shown, so the ground does not move while you read.")
        }

        ToolbarItem { TimeRangeMenu() }
        ToolbarItem { SeverityMenu() }
        ToolbarItem { TagMenu() }

        ToolbarItem {
            Button {
                showJump = true
            } label: {
                Label("Jump to a moment", systemImage: "scope")
            }
            .help("Land on a timestamp and see every node around it (⌘J)")
        }

        ToolbarItem {
            Menu {
                Button("Export as event bundle (JSONL)…") { export(.jsonl) }
                Button("Export as plain text…") { export(.text) }
                Divider()
                Button("Open an event bundle…") { importBundle() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Write what is on screen to a file that can be attached to an issue")
        }

        ToolbarItem {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show the selected event in full")
        }

        ToolbarItem(placement: .principal) { SearchField() }
    }

    // MARK: - Export and import

    private func export(_ format: ExportService.Format) {
        let panel = NSSavePanel()
        panel.title = "Export events"
        panel.nameFieldStringValue = defaultExportName(format)
        panel.allowedContentTypes = [format == .jsonl ? .json : .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Everything matching the current filters, not just the rows on screen."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let filter = model.filter
        let ordering = model.settings.ordering
        let endpoint = model.settings.endpoint
        // No limit: the export is what matches, not what happens to be rendered.
        var query = filter.query(ordering: ordering, limit: Int.max)
        query.limit = Int.max

        do {
            let reader = try model.makeExportReader()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try ExportService.write(
                        to: url, format: format, query: query, filter: filter,
                        endpoint: endpoint, ordering: ordering, reader: reader)
                } catch {
                    Task { @MainActor in exportError = "\(error)" }
                }
            }
        } catch {
            exportError = "\(error)"
        }
    }

    private func defaultExportName(_ format: ExportService.Format) -> String {
        let stamp = Timestamp.format(Timestamp.now(), style: .rfc3339UTC)
            .replacingOccurrences(of: ":", with: "")
            .prefix(15)
        let scope = model.focusedHost ?? "fleet"
        return "mcastsyslog-\(scope)-\(stamp).\(format.fileExtension)"
    }

    private func importBundle() {
        let panel = NSOpenPanel()
        panel.title = "Open an event bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.message = "A JSONL bundle written by mcastsyslog, or by anything producing the same encoding."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (events, _) = try ExportService.read(url)
            guard !events.isEmpty else {
                exportError = "No events in \(url.lastPathComponent)."
                return
            }
            try model.importEvents(events)
        } catch {
            exportError = "\(error)"
        }
    }
}

// MARK: - Menu commands, routed through notifications so the menu bar and the
// toolbar drive the same code.

extension Notification.Name {
    static let mcastJumpToMoment = Notification.Name("mcast.jumpToMoment")
    static let mcastExportJSONL = Notification.Name("mcast.exportJSONL")
    static let mcastExportText = Notification.Name("mcast.exportText")
    static let mcastImportBundle = Notification.Name("mcast.importBundle")
}
