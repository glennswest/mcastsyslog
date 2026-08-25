import SwiftUI

/// One line of the log.
///
/// The node's own notices about volume — a collapsed repeat, a rate-limit drop
/// — and a frame that did not parse are rendered distinctly. They are facts
/// about the node, not noise, and a viewer that lets them pass as ordinary
/// lines has thrown away the most useful thing on the wire.
struct EventRowView: View {
    let event: LogEvent
    let ordering: TimeOrdering
    let showHost: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Timestamp.format(event.time(by: ordering), style: .timeOnly))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(event.flags.contains(.clockUnset)
                                 ? Color(nsColor: .systemOrange)
                                 : Color(nsColor: .secondaryLabelColor))
                .help(timeHelp)

            SeverityBadge(severity: event.severity)

            if showHost {
                Text(event.host)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(event.source == event.host ? event.host : "\(event.host) — from \(event.source)")
            }

            Text(event.tag)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            messageView

            Spacer(minLength: 0)

            flagChips
        }
        .padding(.vertical, 1)
        .listRowBackground(rowBackground)
        .contextMenu { EventContextMenu(event: event) }
    }

    @ViewBuilder
    private var messageView: some View {
        if event.flags.isNodeNotice {
            HStack(spacing: 5) {
                Image(systemName: event.flags.contains(.rateLimitNotice)
                      ? "gauge.with.dots.needle.bottom.50percent" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                Text(event.message)
                    .italic()
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(event.severity.color)
            .textSelection(.enabled)
        } else {
            Text(event.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(event.severity.messageColor)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var flagChips: some View {
        HStack(spacing: 4) {
            if event.flags.contains(.malformed) {
                Chip(text: "malformed", systemImage: "questionmark.diamond.fill",
                     tint: Color(nsColor: .systemPink),
                     help: "This frame did not parse as RFC 5424. It is kept verbatim — see the inspector.")
            }
            if event.flags.contains(.clockUnset) {
                Chip(text: "clock unset", systemImage: "clock.badge.exclamationmark",
                     tint: Color(nsColor: .systemOrange),
                     help: "The node said its clock is not set. Ordered by when we heard it.")
            }
            if event.hasNotableSkew, let skew = event.skewNanos {
                Chip(text: Timestamp.formatInterval(skew), systemImage: "clock.arrow.2.circlepath",
                     tint: Color(nsColor: .systemTeal),
                     help: "Sent and received times disagree by \(Timestamp.formatInterval(skew)).")
            }
        }
    }

    private var rowBackground: some View {
        Group {
            if event.severity.isProblem {
                event.severity.color.opacity(0.06)
            } else if event.flags.contains(.malformed) {
                Color(nsColor: .systemPink).opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    private var timeHelp: String {
        var lines = ["Sent: " + (event.sentNanos.map { Timestamp.format($0, style: .full) } ?? "— (clock unset)")]
        lines.append("Received: " + Timestamp.format(event.recvNanos, style: .full))
        if let skew = event.skewNanos {
            lines.append("Skew: " + Timestamp.formatInterval(skew))
        }
        return lines.joined(separator: "\n")
    }
}

/// The right-click menu. Every item narrows the view or copies something; none
/// of them reaches a node.
struct EventContextMenu: View {
    @EnvironmentObject private var model: StreamModel
    let event: LogEvent

    var body: some View {
        Button("Show this moment across the fleet") { model.showMoment(of: event) }
        Divider()
        Button("Only this node — \(event.host)") {
            var next = model.filter
            next.hosts = [event.host]
            model.filter = next
        }
        Button("Only this tag — \(event.tag)") {
            var next = model.filter
            next.tags = [event.tag]
            model.filter = next
        }
        Divider()
        Button("Copy message") { copy(event.message) }
        Button("Copy line") { copy(ExportFormatter.textLine(event)) }
        Button("Copy timestamp") {
            copy(Timestamp.format(event.time(by: model.settings.ordering), style: .rfc3339UTC))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
