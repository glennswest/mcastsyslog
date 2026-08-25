import Foundation

/// Strips terminal escape sequences from a message for display.
///
/// Real nodes emit coloured output. `stormpump` forwards a workload's stdout to
/// the wire as it was written, so a line that was coloured for a terminal
/// arrives with the escapes still in it — `ESC[33m WARN ESC[0m` and so on.
///
/// The stored message keeps them: it is what the node sent, and this viewer's
/// whole posture is that it does not quietly improve what it heard. But a log
/// viewer that renders raw escape codes is unreadable, so the display and the
/// plain-text export use this, and the API serves both — `message` verbatim,
/// and `message_plain` when the two differ.
public enum PlainText {

    /// True when the text contains anything this would remove — worth checking
    /// before allocating a second copy of every line in a fleet's traffic.
    public static func containsControlSequences(_ text: String) -> Bool {
        text.utf8.contains { $0 == 0x1B || $0 == 0x07 || ($0 < 0x20 && $0 != 0x09) }
    }

    /// The message as a person would read it: CSI and OSC sequences removed,
    /// other C0 controls dropped, tabs kept.
    public static func strip(_ text: String) -> String {
        guard containsControlSequences(text) else { return text }

        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0

        while i < scalars.count {
            let c = scalars[i]

            if c == "\u{1B}" {
                i += 1
                guard i < scalars.count else { break }
                let kind = scalars[i]

                if kind == "[" {
                    // CSI: parameter and intermediate bytes, then a final byte
                    // in @ … ~ that ends the sequence.
                    i += 1
                    while i < scalars.count, scalars[i].value >= 0x30, scalars[i].value <= 0x3F { i += 1 }
                    while i < scalars.count, scalars[i].value >= 0x20, scalars[i].value <= 0x2F { i += 1 }
                    if i < scalars.count { i += 1 }
                } else if kind == "]" {
                    // OSC: runs until BEL, or ST (ESC \).
                    i += 1
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                } else {
                    // A two-character escape.
                    i += 1
                }
                continue
            }

            // Other C0 controls carry no meaning in a single-line message. Tab
            // does, so it stays.
            if c.value < 0x20, c != "\u{09}" {
                i += 1
                continue
            }

            out.append(c)
            i += 1
        }

        return String(out)
    }
}
