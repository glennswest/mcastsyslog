import SwiftUI

/// The bottom line: what is being shown, out of what, at what cost, and over
/// which interfaces.
///
/// The spec's third property is that search admits its limits. This is where it
/// admits them — a scan says it is scanning, says it can be stopped, and a
/// truncated count says it is truncated rather than rounding it into a number
/// that looks exact.
struct StatusBar: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        HStack(spacing: 12) {
            listeningIndicator

            Divider().frame(height: 12)

            Text(shownText)
                .foregroundStyle(.secondary)

            if case .scanning = model.state {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("scanning messages…")
                    Button("Stop") { model.cancelQuery() }
                        .buttonStyle(.link)
                }
                .foregroundStyle(Color(nsColor: .systemOrange))
            } else if case .cancelled = model.state {
                Label("stopped — showing what was found so far", systemImage: "stop.circle")
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else if case .failed(let message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(1)
                    .help(message)
            } else if model.lastQueryNanos > 0 {
                Text(Timestamp.formatInterval(model.lastQueryNanos))
                    .foregroundStyle(.tertiary)
                    .help("How long the last query took")
            }

            Spacer()

            if model.eventsPerSecond >= 0.05 {
                Label(String(format: "%.0f/s", model.eventsPerSecond), systemImage: "waveform.path")
                    .foregroundStyle(.secondary)
                    .help("Events arriving, averaged over the last five seconds")
            }

            if model.receiver.malformed > 0 {
                Button {
                    model.filter.requiredFlags.formUnion(.malformed)
                } label: {
                    Label("\(model.receiver.malformed) malformed", systemImage: "questionmark.diamond")
                }
                .buttonStyle(.link)
                .foregroundStyle(Color(nsColor: .systemPink))
                .help("Frames that did not parse. They are kept verbatim — click to show only these.")
            }

            if model.receiver.backlog > 8 {
                Label("\(model.receiver.backlog) batches queued", systemImage: "tray.full")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("The store is behind the wire. Nothing is asked of the nodes; the kernel buffer absorbs it.")
            }

            Text(ByteCount.format(model.storeStats.bytes))
                .foregroundStyle(.tertiary)
                .help(storeHelp)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var listeningIndicator: some View {
        Button { model.toggleListening() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.receiver.isListening
                          ? (model.receiver.joined.isEmpty ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                          : Color(nsColor: .systemGray))
                    .frame(width: 7, height: 7)
                Text(model.receiver.isListening ? model.settings.endpoint.description : "not listening")
            }
        }
        .buttonStyle(.plain)
        .help(interfaceHelp)
    }

    private var interfaceHelp: String {
        guard model.receiver.isListening else { return "Click to join \(model.settings.endpoint.description)" }
        if let error = model.receiver.lastError { return error }
        guard !model.receiver.joined.isEmpty else {
            return model.settings.endpoint.isMulticast
                ? "Joined no interface yet."
                : "Bound to \(model.settings.endpoint.description) — a unicast address, so there is no group to join."
        }
        let list = model.receiver.joined.map { "\($0.name) (\($0.address))" }.joined(separator: "\n")
        return "Joined on:\n\(list)\n\nClick to stop listening."
    }

    private var shownText: String {
        let shown = model.events.count
        guard shown > 0 else { return "nothing shown" }
        if model.matchCount <= Int64(shown) && model.matchCountExact {
            return "\(shown.formatted()) events"
        }
        let of = model.matchCountExact
            ? model.matchCount.formatted()
            : "more than \(model.matchCount.formatted())"
        return "\(shown.formatted()) of \(of)"
    }

    private var storeHelp: String {
        var lines = ["\(model.storeStats.events.formatted()) events stored, \(model.storeStats.hosts) hosts"]
        if let oldest = model.storeStats.oldestNanos {
            lines.append("oldest: \(Timestamp.format(oldest, style: .full))")
        }
        lines.append("keeping \(String(format: "%.1f", model.settings.retentionGiB)) GiB or \(model.settings.retentionDays) days, whichever comes first")
        return lines.joined(separator: "\n")
    }
}
