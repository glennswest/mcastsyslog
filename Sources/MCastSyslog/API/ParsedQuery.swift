import Foundation

/// Turns query-string parameters into the same `FilterState` and `EventQuery`
/// the window uses.
///
/// Deliberately the same types: a question asked over HTTP and the same
/// question asked in the UI must not be able to give different answers, and the
/// surest way to guarantee that is for there to be only one implementation of
/// what a filter means.
struct ParsedQuery {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let filter: FilterState
    let query: EventQuery

    static let defaultLimit = 200
    static let maximumLimit = 10_000

    init(_ request: HTTPRequest) throws {
        var filter = FilterState()
        filter.hosts = Set(request.list("host"))
        filter.tags = Set(request.list("tag"))

        for name in request.list("severity") {
            guard let severity = Self.severity(name) else {
                throw Failure(message: "`\(name)` is not a severity — use a name (error, warning, …) or 0–7")
            }
            filter.severities.insert(severity)
        }

        if let floor = request.first("min_severity") {
            guard let severity = Self.severity(floor) else {
                throw Failure(message: "`\(floor)` is not a severity — use a name (error, warning, …) or 0–7")
            }
            // "At least this severe" means a lower raw value, since 0 is the
            // worst thing that can happen and 7 is a trace line.
            filter.severities.formUnion(Severity.allCases.filter { $0.rawValue <= severity.rawValue })
        }

        for name in request.list("flag") {
            let flags = ExportFormatter.flags(from: [name])
            guard !flags.isEmpty else {
                throw Failure(message: "`\(name)` is not a flag — use malformed, clock_unset, collapsed_repeat or rate_limited")
            }
            filter.requiredFlags.formUnion(flags)
        }

        if let text = request.first("q"), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            filter.searchText = text
        }
        if let mode = request.first("mode") {
            guard let parsed = SearchMode(rawValue: mode.lowercased()) else {
                throw Failure(message: "`\(mode)` is not a search mode — use tokens or substring")
            }
            filter.searchMode = parsed
        }

        // Time bounds: either a span ending now, or an explicit pair.
        if let last = request.first("last") {
            guard let span = Self.duration(last) else {
                throw Failure(message: "`\(last)` is not a span — try 15m, 2h, 1d, or a number of seconds")
            }
            let now = Timestamp.now()
            filter.range = .window(from: now - span, to: now)
        } else {
            let from = try Self.time(request.first("from"), name: "from")
            let to = try Self.time(request.first("to"), name: "to")
            if from != nil || to != nil {
                filter.range = .window(from: from ?? Int64.min / 2, to: to ?? Int64.max / 2)
            }
        }

        let ordering = Self.ordering(request.first("order"))

        var limit = request.int("limit") ?? Self.defaultLimit
        if limit <= 0 { limit = Self.defaultLimit }
        // Capped rather than honoured-and-hoped: an unbounded limit over HTTP is
        // a way to make the viewer allocate the corpus on someone else's say-so.
        limit = min(limit, Self.maximumLimit)

        // A cursor makes the request a tail rather than a page: everything
        // after this id, oldest first.
        let sinceId = request.first("since_id").flatMap(Int64.init)
        if request.first("since_id") != nil, sinceId == nil {
            throw Failure(message: "`since_id` must be an event id — the `next_since_id` from a previous response")
        }

        self.filter = filter
        self.query = filter.query(ordering: ordering, limit: limit, sinceId: sinceId)
    }

    var isTail: Bool { query.sinceId != nil }

    /// Echoed back on every response, so a caller can see how its parameters
    /// were actually read rather than assuming.
    func describe() -> [String: Any] {
        var described: [String: Any] = [
            "order": query.ordering.rawValue,
            "limit": query.limit,
        ]
        if !filter.hosts.isEmpty { described["host"] = filter.hosts.sorted() }
        if !filter.tags.isEmpty { described["tag"] = filter.tags.sorted() }
        if !filter.severities.isEmpty {
            described["severity"] = filter.severities.sorted().map(\.label)
        }
        if !filter.requiredFlags.isEmpty {
            described["flag"] = ExportFormatter.flagNames(filter.requiredFlags)
        }
        if let search = filter.search {
            described["q"] = search.text
            described["mode"] = search.mode.rawValue
            described["scans"] = search.mode == .substring
        }
        if let from = query.fromNanos, from > Int64.min / 4 {
            described["from"] = Timestamp.format(from, style: .rfc3339UTC)
        }
        if let to = query.toNanos, to < Int64.max / 4 {
            described["to"] = Timestamp.format(to, style: .rfc3339UTC)
        }
        if let sinceId = query.sinceId { described["since_id"] = sinceId }
        return described
    }

    // MARK: - Scalars

    static func severity(_ text: String) -> Severity? {
        let lowered = text.lowercased()
        if let value = Int(lowered), let severity = Severity(rawValue: UInt8(clamping: value)), value >= 0, value <= 7 {
            return severity
        }
        // Accept the names the node's own lines use as well as the RFC's.
        switch lowered {
        case "err", "error", "fatal": return .error
        case "warn", "warning": return .warning
        case "crit", "critical": return .critical
        case "emerg", "emergency", "panic": return .emergency
        case "alert": return .alert
        case "notice", "note": return .notice
        case "info": return .info
        case "debug", "trace": return .debug
        default: return nil
        }
    }

    static func ordering(_ text: String?) -> TimeOrdering {
        switch text?.lowercased() {
        case "receive", "recv", "receivetime", "receive_time": return .receiveTime
        default: return .senderTime
        }
    }

    /// `15m`, `2h`, `1d`, `90s`, or a bare number of seconds — in nanoseconds.
    static func duration(_ text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600), ("d", 86_400), ("w", 604_800)]
        for (suffix, scale) in units.sorted(by: { $0.0.count > $1.0.count }) {
            if text.hasSuffix(suffix), let value = Double(text.dropLast(suffix.count)) {
                return Int64(value * scale * 1e9)
            }
        }
        guard let seconds = Double(text) else { return nil }
        return Int64(seconds * 1e9)
    }

    static func time(_ text: String?, name: String) throws -> Int64? {
        guard let text, !text.isEmpty else { return nil }
        // A relative span is a natural thing to type for a lower bound.
        if text.hasPrefix("-"), let span = duration(String(text.dropFirst())) {
            return Timestamp.now() - span
        }
        guard let nanos = Timestamp.parseFlexible(text) else {
            throw Failure(message: "could not read `\(name)=\(text)` as a time — try RFC 3339, 'YYYY-MM-DD HH:MM:SS', an epoch number, or a relative span like -15m")
        }
        return nanos
    }
}
