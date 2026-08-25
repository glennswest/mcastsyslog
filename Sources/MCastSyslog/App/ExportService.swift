import Foundation
import AppKit

/// The on-disk event encoding.
///
/// One JSON object per line, the first of which is a manifest. Newline-delimited
/// so a bundle can be appended to while it is being written, read with `grep`,
/// and streamed without holding it in memory — and so `must-gather` can produce
/// the same shape from the node side without needing a library to do it.
///
/// The encoding is documented in `docs/EXPORT.md`. It is a format, not an
/// implementation detail: the point of writing it down is that the two tools
/// stay interchangeable.
public enum ExportFormatter {

    public static let formatIdentifier = "mcastsyslog-events-v1"

    /// The plain-text rendering — what the log looks like, for pasting into an
    /// issue where JSON would be unreadable.
    public static func textLine(_ event: LogEvent, ordering: TimeOrdering = .senderTime) -> String {
        let time = Timestamp.format(event.time(by: ordering), style: .full)
        let host = event.host.padding(toLength: max(event.host.count, 14), withPad: " ", startingAt: 0)
        let tag = event.tag.padding(toLength: max(event.tag.count, 12), withPad: " ", startingAt: 0)
        var line = "\(time)  \(event.severity.short)  \(host)  \(tag)  \(event.message)"
        if event.flags.contains(.malformed) { line += "   [malformed]" }
        if event.flags.contains(.clockUnset) { line += "   [clock unset]" }
        return line
    }

    static func flagNames(_ flags: EventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.malformed) { names.append("malformed") }
        if flags.contains(.clockUnset) { names.append("clock_unset") }
        if flags.contains(.repeatNotice) { names.append("collapsed_repeat") }
        if flags.contains(.rateLimitNotice) { names.append("rate_limited") }
        return names
    }

    static func flags(from names: [String]) -> EventFlags {
        var flags: EventFlags = []
        for name in names {
            switch name {
            case "malformed": flags.insert(.malformed)
            case "clock_unset": flags.insert(.clockUnset)
            case "collapsed_repeat": flags.insert(.repeatNotice)
            case "rate_limited": flags.insert(.rateLimitNotice)
            default: break
            }
        }
        return flags
    }

    /// One event as a JSON object. Both times appear twice — as nanoseconds,
    /// which is what the store holds and what round-trips exactly, and as RFC
    /// 3339, which is what a person reading the file needs.
    public static func json(_ event: LogEvent) -> [String: Any] {
        var object: [String: Any] = [
            "recv_ns": event.recvNanos,
            "id": event.id,
            "recv": Timestamp.format(event.recvNanos, style: .rfc3339UTC),
            "host": event.host,
            "tag": event.tag,
            "severity": Int(event.severity.rawValue),
            "severity_name": event.severity.label,
            "facility": Int(event.facility),
            "source": event.source,
            "message": event.message,
        ]
        if let sent = event.sentNanos {
            object["sent_ns"] = sent
            object["sent"] = Timestamp.format(sent, style: .rfc3339UTC)
        }
        let names = flagNames(event.flags)
        if !names.isEmpty { object["flags"] = names }
        if let repeated = event.repeated { object["repeated"] = repeated }
        if let raw = event.raw { object["raw_base64"] = raw.base64EncodedString() }
        // The id is this viewer's row number, which is what `/events/{id}`
        // addresses. It means nothing in another viewer's store, so it is
        // written but deliberately ignored on import.
        if event.id == 0 { object.removeValue(forKey: "id") }
        return object
    }

    public static func event(from object: [String: Any], fallbackReceive: Int64) -> LogEvent? {
        guard let message = object["message"] as? String else { return nil }
        let recv = (object["recv_ns"] as? NSNumber)?.int64Value
            ?? (object["recv"] as? String).flatMap { Timestamp.parseRFC3339($0) }
            ?? fallbackReceive
        let sent = (object["sent_ns"] as? NSNumber)?.int64Value
            ?? (object["sent"] as? String).flatMap { Timestamp.parseRFC3339($0) }
        let severity = Severity(clamping: (object["severity"] as? NSNumber)?.intValue ?? 6)
        return LogEvent(
            recvNanos: recv,
            sentNanos: sent,
            host: object["host"] as? String ?? "-",
            tag: object["tag"] as? String ?? "-",
            severity: severity,
            facility: UInt8(clamping: (object["facility"] as? NSNumber)?.intValue ?? Int(defaultFacility)),
            flags: flags(from: object["flags"] as? [String] ?? []),
            repeated: (object["repeated"] as? NSNumber)?.intValue,
            source: object["source"] as? String ?? "-",
            message: message,
            raw: (object["raw_base64"] as? String).flatMap { Data(base64Encoded: $0) }
        )
    }

    static func manifest(filter: FilterState, endpoint: ListenEndpoint, ordering: TimeOrdering) -> [String: Any] {
        var described: [String: Any] = ["ordering": ordering.rawValue, "range": filter.range.label]
        if !filter.hosts.isEmpty { described["hosts"] = filter.hosts.sorted() }
        if !filter.tags.isEmpty { described["tags"] = filter.tags.sorted() }
        if !filter.severities.isEmpty { described["severities"] = filter.severities.sorted().map(\.label) }
        if !filter.searchText.isEmpty {
            described["search"] = ["mode": filter.searchMode.rawValue, "text": filter.searchText]
        }
        return [
            "mcastsyslog": [
                "format": formatIdentifier,
                "version": AppVersion.current,
                "exported": Timestamp.format(Timestamp.now(), style: .rfc3339UTC),
                "group": endpoint.description,
                "filter": described,
            ]
        ]
    }
}

/// Writing what is on screen to a file that can be attached to an issue, and
/// reading one back in.
public enum ExportService {

    public enum Format: String, CaseIterable {
        case jsonl
        case text

        public var fileExtension: String { self == .jsonl ? "jsonl" : "log" }
        public var label: String { self == .jsonl ? "Event bundle (JSONL)" : "Plain text" }
    }

    /// Stream every matching event to `url`. Streaming rather than collecting:
    /// an export of a day's fleet traffic should not need to fit in memory.
    public static func write(
        to url: URL,
        format: Format,
        query: EventQuery,
        filter: FilterState,
        endpoint: ListenEndpoint,
        ordering: TimeOrdering,
        reader: EventReader
    ) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ExportError.noStore
        }
        defer { try? handle.close() }

        var buffer = Data()
        var written = 0

        func emit(_ line: String) throws {
            buffer.append(contentsOf: Array(line.utf8))
            buffer.append(0x0A)
            if buffer.count > 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if format == .jsonl {
            let manifest = ExportFormatter.manifest(filter: filter, endpoint: endpoint, ordering: ordering)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try emit(String(decoding: data, as: UTF8.self))
        } else {
            try emit("# mcastsyslog \(AppVersion.current) — \(endpoint.description)")
            try emit("# exported \(Timestamp.format(Timestamp.now(), style: .rfc3339UTC)), \(filter.range.label)")
        }

        try reader.forEach(query) { event in
            switch format {
            case .jsonl:
                let data = try JSONSerialization.data(
                    withJSONObject: ExportFormatter.json(event), options: [.sortedKeys])
                try emit(String(decoding: data, as: UTF8.self))
            case .text:
                try emit(ExportFormatter.textLine(event, ordering: ordering))
            }
            written += 1
        }

        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return written
    }

    /// Read a bundle written by this app — or by anything else that produces the
    /// documented encoding, which is the point of documenting it.
    public static func read(_ url: URL) throws -> (events: [LogEvent], manifest: [String: Any]?) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var events: [LogEvent] = []
        var manifest: [String: Any]?
        let now = Timestamp.now()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let header = object["mcastsyslog"] as? [String: Any] {
                manifest = header
                continue
            }
            if let event = ExportFormatter.event(from: object, fallbackReceive: now) {
                events.append(event)
            }
        }
        return (events, manifest)
    }
}
