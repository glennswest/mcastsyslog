import SwiftUI

/// The fleet: nodes as rows, event rate and worst severity as columns, and one
/// click to drill into a single node's stream.
///
/// The list is what the store has heard from in the last five minutes, plus
/// every host it has ever heard from — a node that has gone silent is exactly
/// the one worth being able to select.
struct FleetSidebar: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                allNodesRow
            }

            Section("Nodes") {
                ForEach(rows) { row in
                    FleetRow(row: row).tag(row.host as String?)
                }
                if rows.isEmpty {
                    Text("No node has said anything yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { receiverFooter }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.focusedHost }, set: { model.focus(host: $0) })
    }

    private var allNodesRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("All nodes").font(.system(size: 12, weight: .medium))
                Text(fleetSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let worst = rows.map(\.worst).min(), worst.isProblem {
                Image(systemName: worst.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(worst.color)
            }
        }
        .tag(String?.none)
    }

    private var fleetSummary: String {
        guard !rows.isEmpty else { return "nothing heard" }
        let rate = rows.reduce(0.0) { $0 + $1.rate }
        let talking = rows.filter { $0.rate > 0 }.count
        return "\(rows.count) known · \(talking) talking · \(String(format: "%.0f", rate))/s"
    }

    /// Every host in the directory, carrying its live numbers when it has any.
    private var rows: [FleetNode] {
        let live = Dictionary(uniqueKeysWithValues: model.fleet.map { ($0.host, $0) })
        let quiet = model.knownHosts.filter { live[$0] == nil }.map { host in
            FleetNode(host: host, source: "", events: 0, worst: .info,
                      lastNanos: 0, firstNanos: 0, rate: 0, clockUnset: false, malformed: 0)
        }
        return (model.fleet + quiet).sorted { lhs, rhs in
            // Loudest and worst first — the node you need is rarely the one
            // alphabetically first.
            if lhs.worst != rhs.worst { return lhs.worst < rhs.worst }
            if lhs.rate != rhs.rate { return lhs.rate > rhs.rate }
            return lhs.host < rhs.host
        }
    }

    private var receiverFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: model.receiver.isListening
                      ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(model.receiver.isListening ? Color(nsColor: .systemGreen) : .secondary)
                Text(model.receiver.isListening ? model.settings.endpoint.description : "not listening")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
            }
            if !model.receiver.joined.isEmpty {
                Text(model.receiver.joined.map(\.name).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Joined on " + model.receiver.joined.map { "\($0.name) (\($0.address))" }
                            .joined(separator: ", "))
            } else if let error = model.receiver.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

struct FleetRow: View {
    let row: FleetNode

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(row.worst.isProblem ? row.worst.color : (row.rate > 0 ? Color(nsColor: .systemGreen) : Color(nsColor: .quaternaryLabelColor)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.host)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 4) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if row.clockUnset {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .help("This node says its clock is not set.")
                    }
                    if row.malformed > 0 {
                        Image(systemName: "questionmark.diamond")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(nsColor: .systemPink))
                            .help("\(row.malformed) frames from this node did not parse.")
                    }
                }
            }

            Spacer(minLength: 4)

            if row.rate > 0 {
                Text(String(format: row.rate < 10 ? "%.1f/s" : "%.0f/s", row.rate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(row.events.formatted()) events in the last five minutes")
            }
        }
        .padding(.vertical, 1)
        .help(row.source.isEmpty ? row.host : "\(row.host) — \(row.source)")
    }

    private var detail: String {
        guard row.lastNanos > 0 else { return "silent" }
        let age = Timestamp.now() - row.lastNanos
        if age < 3_000_000_000 { return row.worst.label }
        return "\(row.worst.label) · \(Timestamp.formatInterval(age)) ago"
    }
}
