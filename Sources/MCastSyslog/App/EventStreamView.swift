import SwiftUI

/// The log itself.
///
/// A live tail that keeps up is the first property in the spec, so this appends
/// rather than re-queries, and it only follows the tail while the user is
/// actually at the tail. Scrolling up stops the ground moving under you.
struct EventStreamView: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        VStack(spacing: 0) {
            if model.filter.isActive { ActiveFilterBar() }

            Divider()

            if model.events.isEmpty {
                EmptyStreamView()
            } else {
                eventList
            }

            Divider()
            StatusBar()
        }
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(model.events) { event in
                    EventRowView(
                        event: event,
                        ordering: model.settings.ordering,
                        showHost: model.focusedHost == nil
                    )
                    .id(event.id)
                    .tag(event.id)
                }
                // An anchor at the very bottom, so following scrolls past the
                // last row rather than to it.
                Color.clear
                    .frame(height: 1)
                    .id(Self.tailAnchor)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 18)
            .onChange(of: model.events.count) {
                guard model.isFollowing else { return }
                withAnimation(.none) { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
            }
            .onChange(of: model.selection) {
                if model.selection != nil { model.showInspector = true }
            }
            .overlay(alignment: .bottomTrailing) { unseenPill }
        }
    }

    private static let tailAnchor = Int64(-1)

    @ViewBuilder
    private var unseenPill: some View {
        if model.unseen > 0 && !model.isFollowing {
            Button {
                model.isFollowing = true
            } label: {
                Label("\(model.unseen) new", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(10)
            .help("Jump back to the live tail")
        }
    }
}

/// Nothing to show, and why. An empty log viewer that says nothing is
/// indistinguishable from a broken one.
struct EmptyStreamView: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !model.receiver.isListening {
                Button("Start listening") { model.startListening() }
                    .controlSize(.large)
                    .padding(.top, 4)
            } else if model.filter.isActive {
                Button("Clear filters") { model.filter = FilterState() }
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        if !model.receiver.isListening { return "antenna.radiowaves.left.and.right.slash" }
        if model.filter.isActive { return "line.3.horizontal.decrease.circle" }
        return "waveform"
    }

    private var title: String {
        if !model.receiver.isListening { return "Not listening" }
        if model.filter.isActive { return "Nothing matches" }
        return "Nothing has arrived yet"
    }

    private var detail: String {
        if let error = model.receiver.lastError, !model.receiver.isListening {
            return error
        }
        if !model.receiver.isListening {
            return "Join \(model.settings.endpoint.description) to see what the fleet is saying."
        }
        if model.filter.isActive {
            return "No stored event matches these filters. The stream is still being recorded — the filters only decide what is shown."
        }
        let joined = model.receiver.joined.map(\.name).joined(separator: ", ")
        return joined.isEmpty
            ? "Listening on \(model.settings.endpoint.description), but no interface has accepted a membership yet."
            : "Listening on \(model.settings.endpoint.description) via \(joined). Nodes emit only when they have something to say."
    }
}

/// The filters currently in force, each one removable. A filter you cannot see
/// is a filter you will forget you set, and then misread the log because of.
struct ActiveFilterBar: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if model.filter.range != .live {
                    removable(model.filter.range.label, "clock") { model.filter.range = .live }
                }
                ForEach(model.filter.hosts.sorted(), id: \.self) { host in
                    removable(host, "desktopcomputer") { model.filter.hosts.remove(host) }
                }
                ForEach(model.filter.tags.sorted(), id: \.self) { tag in
                    removable(tag, "tag") { model.filter.tags.remove(tag) }
                }
                ForEach(model.filter.severities.sorted(), id: \.self) { severity in
                    removable(severity.label, severity.symbol) { model.filter.severities.remove(severity) }
                }
                if model.filter.requiredFlags.contains(.malformed) {
                    removable("malformed only", "questionmark.diamond") {
                        model.filter.requiredFlags.remove(.malformed)
                    }
                }
                if !model.filter.searchText.isEmpty {
                    removable("\(model.filter.searchMode.label): \(model.filter.searchText)",
                              "magnifyingglass") { model.filter.searchText = "" }
                }
                Button("Clear all") { model.filter = FilterState() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func removable(_ text: String, _ symbol: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(text).font(.system(size: 11))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
    }
}
