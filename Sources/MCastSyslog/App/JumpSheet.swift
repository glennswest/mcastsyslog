import SwiftUI

/// Jump to a moment.
///
/// Given a timestamp — from a bug report, a ticket, or another tool — land on it
/// and show what surrounded it, on every node at once. This is the view that
/// makes multicast worth having: one node's failure is usually visible in
/// another node's log first, and neither node knows about the other.
struct JumpSheet: View {
    @EnvironmentObject private var model: StreamModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var windowSeconds: Double = 30
    @FocusState private var focused: Bool

    private var parsed: Int64? { Timestamp.parseFlexible(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Jump to a moment").font(.headline)
                Text("Every node's log around one instant — not just the one you were reading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("2026-08-24T21:47:11.123456Z", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(go)

            HStack(spacing: 6) {
                if let parsed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
                    Text(Timestamp.format(parsed, style: .full))
                        .font(.system(size: 11, design: .monospaced))
                    Text("·").foregroundStyle(.tertiary)
                    Text(Timestamp.formatInterval(Timestamp.now() - parsed) + " ago")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if text.isEmpty {
                    Text("RFC 3339, `2026-08-24 21:47:11`, a bare date, or an epoch number.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                    Text("Not a timestamp this recognises.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 16)

            HStack {
                Text("Show").font(.callout)
                Picker("", selection: $windowSeconds) {
                    Text("±5s").tag(5.0)
                    Text("±30s").tag(30.0)
                    Text("±2m").tag(120.0)
                    Text("±10m").tag(600.0)
                    Text("±1h").tag(3600.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Button("Paste") { paste() }
                    .help("Take a timestamp from the clipboard")
                if let newest = model.storeStats.newestNanos {
                    Button("Newest") { text = Timestamp.format(newest, style: .rfc3339UTC) }
                        .help("The most recent event in the store")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Jump") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            focused = true
            if let clipboard = NSPasteboard.general.string(forType: .string),
               Timestamp.parseFlexible(clipboard) != nil {
                text = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func paste() {
        if let clipboard = NSPasteboard.general.string(forType: .string) {
            text = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func go() {
        guard let parsed else { return }
        model.jump(to: parsed, window: windowSeconds)
        dismiss()
    }
}
