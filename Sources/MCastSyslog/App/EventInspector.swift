import SwiftUI

/// Everything about one event, including the parts the row has no room for:
/// both times and the distance between them, the address it really came from,
/// and — when the frame did not parse — the bytes themselves.
struct EventInspector: View {
    @EnvironmentObject private var model: StreamModel

    var body: some View {
        Group {
            if let event = model.selectedEvent {
                detail(event)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select an event")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 280)
    }

    private func detail(_ event: LogEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(event)

                Section2("Message") {
                    Text(PlainText.strip(event.message))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                }

                Section2("Time") {
                    Field("Sent", event.sentNanos.map { Timestamp.format($0, style: .full) }
                          ?? "— the node said its clock is not set")
                    Field("Received", Timestamp.format(event.recvNanos, style: .full))
                    if let skew = event.skewNanos {
                        Field("Skew", Timestamp.formatInterval(skew),
                              note: event.hasNotableSkew
                              ? "The node's clock and this Mac's disagree. A node replaying a boot's backlog looks exactly like this, and is not a fault."
                              : nil)
                    }
                    Field("UTC", Timestamp.format(event.time(by: model.settings.ordering), style: .rfc3339UTC))
                }

                Section2("Origin") {
                    Field("Host", event.host)
                    Field("From", event.source,
                          note: event.source == event.host ? nil
                          : "The frame's hostname and the address it arrived from differ.")
                    Field("Tag", event.tag)
                    Field("Severity", "\(event.severity.label) (\(event.severity.rawValue))")
                    Field("Facility", "\(event.facility)")
                    if let repeated = event.repeated {
                        Field("Count", "\(repeated)")
                    }
                }

                if !event.flags.isEmpty {
                    Section2("Flags") { flagList(event) }
                }

                if let raw = event.raw {
                    Section2("Frame, verbatim") {
                        Text(String(decoding: raw, as: UTF8.self))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        Text(HexDump.format(raw, limit: 512))
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    model.showMoment(of: event)
                } label: {
                    Label("Show this moment across the fleet", systemImage: "scope")
                }
                .controlSize(.small)
                .help("What every other node was saying at the same instant.")
            }
            .padding(12)
        }
    }

    private func header(_ event: LogEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.severity.symbol)
                .font(.system(size: 16))
                .foregroundStyle(event.severity.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.host).font(.system(size: 13, weight: .semibold))
                Text(Timestamp.format(event.time(by: model.settings.ordering), style: .full))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func flagList(_ event: LogEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if event.flags.contains(.malformed) {
                FlagNote("malformed", "questionmark.diamond.fill", Color(nsColor: .systemPink),
                         "This frame did not parse as RFC 5424. It is kept exactly as it arrived rather than dropped — a viewer that hides what it cannot parse hides the interesting failures.")
            }
            if event.flags.contains(.clockUnset) {
                FlagNote("clock unset", "clock.badge.exclamationmark", Color(nsColor: .systemOrange),
                         "The node sent the nil timestamp. It syncs NTP in the initramfs precisely so its times are real; when it could not, it says so rather than inventing one. This event is ordered by when we heard it.")
            }
            if event.flags.contains(.repeatNotice) {
                FlagNote("collapsed repeat", "arrow.triangle.2.circlepath", Color(nsColor: .systemYellow),
                         "The node collapsed a run of identical lines. This is the node defending the wire, and a fact about the node rather than noise.")
            }
            if event.flags.contains(.rateLimitNotice) {
                FlagNote("rate limited", "gauge.with.dots.needle.bottom.50percent", Color(nsColor: .systemOrange),
                         "The node's token bucket ran dry — 200 lines/s sustained, 2000 banked — and it is announcing what it held back.")
            }
        }
    }
}

private struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            content
        }
    }
}

private struct Field: View {
    let label: String
    let value: String
    var note: String?

    init(_ label: String, _ value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 68)
            }
        }
    }
}

private struct FlagNote: View {
    let title: String
    let symbol: String
    let tint: Color
    let explanation: String

    init(_ title: String, _ symbol: String, _ tint: Color, _ explanation: String) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.explanation = explanation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(explanation).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

/// For a frame that did not parse: the bytes, so the reason is visible even
/// when it is not printable.
enum HexDump {
    static func format(_ data: Data, limit: Int) -> String {
        let slice = data.prefix(limit)
        var lines: [String] = []
        for offset in stride(from: 0, to: slice.count, by: 16) {
            let chunk = Array(slice[slice.startIndex + offset ..< min(slice.startIndex + offset + 16, slice.endIndex)])
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %-47@  %@", offset, hex as NSString, ascii as NSString))
        }
        if data.count > limit {
            lines.append("… \(data.count - limit) more bytes")
        }
        return lines.joined(separator: "\n")
    }
}
