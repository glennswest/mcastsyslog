import Foundation

/// Parses RFC 5424 frames off the wire.
///
/// Tolerant by contract: `parse` always returns an event. A frame that does not
/// parse comes back verbatim with severity `info` and the `malformed` flag,
/// because a viewer that hides what it cannot parse hides exactly the
/// interesting failures.
///
/// Byte-level on purpose. `DateFormatter` and `Scanner` are both far too slow
/// for a fleet's worth of datagrams, and the grammar here is small enough that
/// reading it directly is shorter than configuring something general.
public enum SyslogParser {

    /// The largest frame the node will send. Anything longer is a payload, not
    /// a log; the receiver truncates, and the flag says so.
    public static let maxFrameBytes = 8 * 1024

    public static func parse(_ datagram: Data, from source: String, receivedAt recvNanos: Int64) -> LogEvent {
        datagram.withUnsafeBytes { raw in
            parse(raw.bindMemory(to: UInt8.self), datagram: datagram, from: source, receivedAt: recvNanos)
        }
    }

    static func parse(
        _ bytes: UnsafeBufferPointer<UInt8>,
        datagram: Data,
        from source: String,
        receivedAt recvNanos: Int64
    ) -> LogEvent {
        var s = Scanner(bytes)
        s.trimTrailingLineEnd()

        func malformed() -> LogEvent {
            // Everything after the trim, verbatim, so nothing is lost — including
            // whatever made it unparseable.
            LogEvent(
                recvNanos: recvNanos,
                sentNanos: nil,
                host: source,
                tag: "-",
                severity: .info,
                facility: defaultFacility,
                flags: [.malformed, .clockUnset],
                source: source,
                message: s.remainderString(),
                raw: datagram
            )
        }

        guard let pri = s.takePRI(), s.takeVersion() == 1, s.takeSpace() else { return malformed() }
        guard let timestampField = s.takeField(),
              let host = s.takeField(),
              let tag = s.takeField(),
              s.takeField() != nil,                 // PROCID, unused by the node
              s.takeField() != nil,                 // MSGID, likewise
              s.skipStructuredData()                // `-`, or bracketed elements
        else { return malformed() }

        _ = s.takeSpace()
        s.skipBOM()
        let message = s.remainderString()

        var flags: EventFlags = []
        var sentNanos: Int64?
        if timestampField == "-" {
            flags.insert(.clockUnset)
        } else if let ns = Timestamp.parseRFC3339(timestampField) {
            // A node whose clock is unset is supposed to send `-`. If one sends a
            // timestamp from before 2020 anyway, believe the flag, not the time.
            if ns < Timestamp.year2020 {
                flags.insert(.clockUnset)
            } else {
                sentNanos = ns
            }
        } else {
            // A header that is otherwise well-formed with an unreadable time is
            // still worth more parsed than not. Keep it, and say the time is not
            // to be trusted.
            flags.insert(.clockUnset)
        }

        let notice = NodeNotice.detect(in: message)
        flags.formUnion(notice.flags)

        return LogEvent(
            recvNanos: recvNanos,
            sentNanos: sentNanos,
            host: host == "-" ? source : host,
            tag: tag,
            severity: Severity(clamping: pri % 8),
            facility: UInt8(clamping: pri / 8),
            flags: flags,
            repeated: notice.count,
            source: source,
            message: message,
            raw: nil
        )
    }
}

// MARK: - The node's notices about its own volume

/// The node defends the wire before the viewer ever sees it: it collapses runs
/// of identical lines and rate-limits per source, and announces both. These are
/// facts about the node, so they are recognised and rendered distinctly rather
/// than passing as ordinary lines.
enum NodeNotice {
    static func detect(in message: String) -> (flags: EventFlags, count: Int?) {
        if message.hasPrefix("last message repeated ") {
            let rest = message.dropFirst("last message repeated ".count)
            return ([.repeatNotice], leadingInt(rest))
        }
        // `N message(s) dropped — over 200 lines/s`
        if let n = leadingInt(Substring(message)), message.contains(" dropped") {
            return ([.rateLimitNotice], n)
        }
        return ([], nil)
    }

    private static func leadingInt(_ s: Substring) -> Int? {
        var value = 0
        var digits = 0
        for ch in s.utf8 {
            guard ch >= 0x30, ch <= 0x39 else { break }
            value = value * 10 + Int(ch - 0x30)
            digits += 1
            if digits > 18 { return nil }
        }
        return digits > 0 ? value : nil
    }
}

// MARK: - Byte scanner

/// A cursor over one datagram. Fields in RFC 5424's header are space-delimited
/// and never contain a space, so most of this is "take bytes up to the next
/// space".
struct Scanner {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var i: Int
    private var end: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        self.i = 0
        self.end = bytes.count
    }

    private static let space: UInt8 = 0x20

    mutating func trimTrailingLineEnd() {
        while end > i {
            let c = bytes[end - 1]
            guard c == 0x0A || c == 0x0D || c == 0x00 else { break }
            end -= 1
        }
    }

    /// `<PRI>` — at most three digits, at most 191.
    mutating func takePRI() -> Int? {
        guard i < end, bytes[i] == 0x3C else { return nil }   // '<'
        i += 1
        var value = 0
        var digits = 0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39, digits < 3 {
            value = value * 10 + Int(bytes[i] - 0x30)
            i += 1
            digits += 1
        }
        guard digits > 0, i < end, bytes[i] == 0x3E, value <= 191 else { return nil }  // '>'
        i += 1
        return value
    }

    mutating func takeVersion() -> Int? {
        var value = 0
        var digits = 0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39, digits < 2 {
            value = value * 10 + Int(bytes[i] - 0x30)
            i += 1
            digits += 1
        }
        return digits > 0 ? value : nil
    }

    mutating func takeSpace() -> Bool {
        guard i < end, bytes[i] == Self.space else { return false }
        i += 1
        return true
    }

    /// One space-delimited header field, consuming the delimiter.
    mutating func takeField() -> String? {
        let start = i
        while i < end, bytes[i] != Self.space { i += 1 }
        guard i > start else { return nil }
        let field = string(start, i)
        guard i < end else { return nil }   // a header field must be followed by SP
        i += 1
        return field
    }

    /// STRUCTURED-DATA: the NILVALUE `-`, or a run of `[id param="value" …]`
    /// elements. The node sends `-` today; the spec's open questions (a
    /// per-source sequence number, a signature) would put them here, so this
    /// skips them correctly rather than assuming the dash.
    mutating func skipStructuredData() -> Bool {
        guard i < end else { return false }
        if bytes[i] == 0x2D {   // '-'
            i += 1
            return i == end || bytes[i] == Self.space
        }
        guard bytes[i] == 0x5B else { return false }   // '['
        while i < end, bytes[i] == 0x5B {
            i += 1
            var inQuotes = false
            var closed = false
            while i < end {
                let c = bytes[i]
                if inQuotes {
                    if c == 0x5C, i + 1 < end {        // '\' escapes the next byte
                        i += 2
                        continue
                    }
                    if c == 0x22 { inQuotes = false }  // '"'
                } else {
                    if c == 0x22 { inQuotes = true }
                    else if c == 0x5D { closed = true; i += 1; break }   // ']'
                }
                i += 1
            }
            guard closed else { return false }
        }
        return i == end || bytes[i] == Self.space
    }

    /// RFC 5424 allows the message to begin with a UTF-8 BOM. It is not content.
    mutating func skipBOM() {
        if end - i >= 3, bytes[i] == 0xEF, bytes[i + 1] == 0xBB, bytes[i + 2] == 0xBF {
            i += 3
        }
    }

    mutating func remainderString() -> String {
        let s = string(i, end)
        i = end
        return s
    }

    /// Invalid UTF-8 becomes U+FFFD rather than a failure. A node emitting a
    /// broken byte in the middle of a line is telling us something; dropping the
    /// line would throw that away.
    private func string(_ from: Int, _ to: Int) -> String {
        guard to > from, let base = bytes.baseAddress else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + from, count: to - from), as: UTF8.self)
    }
}
