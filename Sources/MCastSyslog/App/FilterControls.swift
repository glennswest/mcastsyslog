import SwiftUI

/// Search, with the two modes visible rather than inferred.
///
/// The spec's third property: search that admits its limits. Which mode you are
/// in is on screen, what each one costs is in its explanation, and a scan says
/// so in the status bar while it runs.
struct SearchField: View {
    @EnvironmentObject private var model: StreamModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search messages", text: $model.filter.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(minWidth: 160, idealWidth: 260)
                .focused($focused)

            if !model.filter.searchText.isEmpty {
                Button {
                    model.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Picker("", selection: $model.filter.searchMode) {
                ForEach(SearchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(model.filter.searchMode.explanation)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .onReceive(NotificationCenter.default.publisher(for: .mcastFocusSearch)) { _ in focused = true }
    }
}

/// Severity as a control, not query syntax. "At least this severe" is the
/// common case, so it gets buttons; the individual levels compose underneath.
struct SeverityMenu: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        Menu {
            Button("All severities") { model.filter.severities = [] }
            Divider()
            Section("At least") {
                ForEach([Severity.error, .warning, .notice, .info], id: \.self) { floor in
                    Button(atLeastLabel(floor)) {
                        model.filter.severities = Set(Severity.allCases.filter { $0.rawValue <= floor.rawValue })
                    }
                }
            }
            Section("Exactly") {
                ForEach(Severity.allCases, id: \.self) { severity in
                    Toggle(isOn: binding(for: severity)) {
                        Label(severity.label, systemImage: severity.symbol)
                    }
                }
            }
            Divider()
            Section("What the node said about itself") {
                Toggle("Only collapsed repeats", isOn: flagBinding(.repeatNotice))
                Toggle("Only rate-limit notices", isOn: flagBinding(.rateLimitNotice))
                Toggle("Only frames that did not parse", isOn: flagBinding(.malformed))
            }
        } label: {
            Label(label, systemImage: "exclamationmark.triangle")
        }
        .help("Filter by severity, and by the node's own notices about its volume")
    }

    private func atLeastLabel(_ floor: Severity) -> String {
        switch floor {
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .notice: return "Notices"
        default: return "Info"
        }
    }

    private var label: String {
        let selected = model.filter.severities
        if selected.isEmpty { return "All" }
        if selected.count == 1 { return selected.first!.label }
        return "\(selected.count) levels"
    }

    private func binding(for severity: Severity) -> Binding<Bool> {
        Binding(
            get: { model.filter.severities.contains(severity) },
            set: { on in
                if on { model.filter.severities.insert(severity) }
                else { model.filter.severities.remove(severity) }
            }
        )
    }

    /// One toggle per flag. Flags are required together rather than in the
    /// alternative — "collapsed repeats and rate limits" is not a thing a single
    /// event can be, so offering it as one control would be a lie.
    private func flagBinding(_ flag: EventFlags) -> Binding<Bool> {
        Binding(
            get: { model.filter.requiredFlags.contains(flag) },
            set: { on in
                if on { model.filter.requiredFlags.insert(flag) }
                else { model.filter.requiredFlags.remove(flag) }
            }
        )
    }
}

/// Tags — the workload a line came from.
struct TagMenu: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        Menu {
            Button("All tags") { model.filter.tags = [] }
            Divider()
            ForEach(model.knownTags, id: \.self) { tag in
                Toggle(isOn: binding(for: tag)) { Text(tag) }
            }
            if model.knownTags.isEmpty {
                Text("Nothing heard yet").foregroundStyle(.secondary)
            }
        } label: {
            Label(label, systemImage: "tag")
        }
        .help("Filter by the workload the line came from")
    }

    private var label: String {
        let selected = model.filter.tags
        if selected.isEmpty { return "All tags" }
        if selected.count == 1 { return selected.first! }
        return "\(selected.count) tags"
    }

    private func binding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { model.filter.tags.contains(tag) },
            set: { on in
                if on { model.filter.tags.insert(tag) } else { model.filter.tags.remove(tag) }
            }
        )
    }
}

struct TimeRangeMenu: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        Menu {
            ForEach(TimeRange.presets, id: \.self) { range in
                Button {
                    model.filter.range = range
                    if range == .live { model.isFollowing = true }
                } label: {
                    if model.filter.range == range {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
            if case .window = model.filter.range {
                Divider()
                Text(model.filter.range.label)
            }
            Divider()
            Picker("Order by", selection: Binding(
                get: { model.settings.ordering },
                set: { model.settings.ordering = $0 }
            )) {
                ForEach(TimeOrdering.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            Label(model.filter.range.label, systemImage: "clock")
        }
        .help("The span in view, and which of the two times it is measured in")
    }
}

extension Notification.Name {
    static let mcastFocusSearch = Notification.Name("mcast.focusSearch")
}
