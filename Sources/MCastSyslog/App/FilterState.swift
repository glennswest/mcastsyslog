import Foundation

/// The time span in view. `live` means "the tail" — no lower bound, and new
/// events belong on screen the moment they arrive.
public enum TimeRange: Equatable, Hashable, Sendable {
    case live
    case lastMinutes(Int)
    case window(from: Int64, to: Int64)

    public var label: String {
        switch self {
        case .live: return "Live"
        case .lastMinutes(let m):
            if m < 60 { return "Last \(m)m" }
            if m % 60 == 0 { return "Last \(m / 60)h" }
            return "Last \(m / 60)h \(m % 60)m"
        case .window(let from, let to):
            return "\(Timestamp.format(from, style: .timeOnly) ) – \(Timestamp.format(to, style: .timeOnly))"
        }
    }

    /// Whether events arriving now belong in this range.
    public var isLive: Bool {
        switch self {
        case .live, .lastMinutes: return true
        case .window: return false
        }
    }

    public static let presets: [TimeRange] = [
        .live, .lastMinutes(5), .lastMinutes(15), .lastMinutes(60),
        .lastMinutes(6 * 60), .lastMinutes(24 * 60),
    ]
}

/// Filters as controls, not query syntax. Everything here composes, and every
/// one of them narrows an index range.
public struct FilterState: Equatable, Sendable {
    public var hosts: Set<String> = []
    public var tags: Set<String> = []
    public var severities: Set<Severity> = []
    public var requiredFlags: EventFlags = []
    public var searchText: String = ""
    public var searchMode: SearchMode = .tokens
    public var range: TimeRange = .live

    public init() {}

    public var isActive: Bool {
        !hosts.isEmpty || !tags.isEmpty || !severities.isEmpty
            || !requiredFlags.isEmpty || !searchText.isEmpty || range != .live
    }

    public var search: SearchSpec? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : SearchSpec(text: trimmed, mode: searchMode)
    }

    /// The query this asks of the store, at this moment.
    public func query(ordering: TimeOrdering, limit: Int, now: Int64 = Timestamp.now()) -> EventQuery {
        var q = EventQuery()
        q.hosts = hosts
        q.tags = tags
        q.severities = severities
        q.requiredFlags = requiredFlags
        q.ordering = ordering
        q.search = search
        q.limit = limit
        switch range {
        case .live:
            break
        case .lastMinutes(let minutes):
            q.fromNanos = now - Int64(minutes) * 60 * 1_000_000_000
        case .window(let from, let to):
            q.fromNanos = from
            q.toNanos = to
        }
        return q
    }

    /// Whether a newly arrived event belongs on screen without re-querying.
    ///
    /// This mirrors what the SQL does. It has to: the live tail appends without
    /// asking the database anything, so the two must agree about what matches or
    /// the view would drift from the corpus behind it.
    public func matches(_ event: LogEvent, ordering: TimeOrdering, now: Int64 = Timestamp.now()) -> Bool {
        guard range.isLive else { return false }
        if case .lastMinutes(let minutes) = range {
            guard event.time(by: ordering) >= now - Int64(minutes) * 60 * 1_000_000_000 else { return false }
        }
        if !hosts.isEmpty, !hosts.contains(event.host) { return false }
        if !tags.isEmpty, !tags.contains(event.tag) { return false }
        if !severities.isEmpty, !severities.contains(event.severity) { return false }
        if !requiredFlags.isEmpty, !event.flags.isSuperset(of: requiredFlags) { return false }

        guard let search, !search.isEmpty else { return true }
        switch search.mode {
        case .substring:
            return event.message.range(of: search.text, options: .caseInsensitive) != nil
        case .tokens:
            // FTS5 with a trailing `*` on each term: every term must match some
            // word in the message, as a prefix of that word.
            let terms = search.text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let words = event.message.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return terms.allSatisfy { term in
                let needle = term.lowercased()
                return words.contains { $0.hasPrefix(needle) }
            }
        }
    }
}
