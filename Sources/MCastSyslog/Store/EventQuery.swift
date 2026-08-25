import Foundation

/// How the search box is being read. The distinction is not cosmetic: one of
/// these is a lookup and the other is a scan, and the viewer says which.
public enum SearchMode: String, CaseIterable, Codable, Sendable {
    /// FTS5 over the message. A prefix lookup — instant, whatever the corpus.
    case tokens
    /// A substring that need not fall on a token boundary. A scan, bounded by
    /// the time range in view, announced as a scan, and cancellable.
    case substring

    public var label: String {
        switch self {
        case .tokens: return "Words"
        case .substring: return "Substring"
        }
    }

    public var explanation: String {
        switch self {
        case .tokens:
            return "Whole words and word prefixes, from the index. Instant at any size."
        case .substring:
            return "Any substring, by reading the messages in the time range in view. Slower, and cancellable."
        }
    }
}

public struct SearchSpec: Equatable, Sendable {
    public var text: String
    public var mode: SearchMode

    public init(text: String, mode: SearchMode) {
        self.text = text
        self.mode = mode
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// User text as an FTS5 MATCH expression.
    ///
    /// Every term is quoted, so a stray `"` or `*` in a log message someone
    /// pasted is a search term rather than a syntax error, and every term gets a
    /// prefix `*` so typing half a word finds the word.
    var ftsExpression: String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { term in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }
}

/// Filters, as controls rather than query syntax, and composable — every one of
/// them narrows an ordered index range, so adding another makes the query
/// faster rather than slower.
public struct EventQuery: Equatable, Sendable {
    /// Empty means every host. Likewise tags and severities.
    public var hosts: Set<String> = []
    public var tags: Set<String> = []
    public var severities: Set<Severity> = []
    /// Every flag here must be present — "only the malformed frames", "only the
    /// node's own notices about volume".
    public var requiredFlags: EventFlags = []
    public var fromNanos: Int64?
    public var toNanos: Int64?
    public var ordering: TimeOrdering = .senderTime
    public var search: SearchSpec?
    /// The page size. A log viewer that tries to hold the corpus in a table is a
    /// log viewer that beachballs.
    public var limit: Int = 3000

    public init() {}

    /// The column that this query's time bounds and ordering apply to.
    ///
    /// `event_ns` is a stored expression for `COALESCE(sent_ns, recv_ns)`: a
    /// node with no clock gets ordered by when we heard it, which is the only
    /// answer available, and the index makes that ordering as cheap as the
    /// other one.
    var timeColumn: String {
        switch ordering {
        case .senderTime: return "event_ns"
        case .receiveTime: return "recv_ns"
        }
    }

    public var isFiltered: Bool {
        !hosts.isEmpty || !tags.isEmpty || !severities.isEmpty
            || !requiredFlags.isEmpty || fromNanos != nil || toNanos != nil
            || !(search?.isEmpty ?? true)
    }

    /// True when answering this needs a scan rather than an index lookup, and
    /// the viewer therefore owes the user a "scanning…" and a way to stop.
    public var requiresScan: Bool {
        guard let search, !search.isEmpty else { return false }
        return search.mode == .substring
    }
}

/// A value bound into a prepared statement.
///
/// Named `SQLValue` rather than the more obvious `Binding` because this module
/// also contains SwiftUI views, and a file-scope `Binding` would shadow
/// SwiftUI's in every one of them.
enum SQLValue {
    case int(Int64)
    case text(String)
}

/// The WHERE clause and its bindings, built once and reused for the page query,
/// the count and the export.
struct QueryPredicate {
    var sql: String
    var bindings: [SQLValue]
    var needsFTSJoin: Bool

    init(_ query: EventQuery) {
        var clauses: [String] = []
        var bindings: [SQLValue] = []

        if let from = query.fromNanos {
            clauses.append("e.\(query.timeColumn) >= ?")
            bindings.append(.int(from))
        }
        if let to = query.toNanos {
            clauses.append("e.\(query.timeColumn) <= ?")
            bindings.append(.int(to))
        }
        if !query.hosts.isEmpty {
            clauses.append("e.host IN (\(Self.placeholders(query.hosts.count)))")
            bindings.append(contentsOf: query.hosts.sorted().map { SQLValue.text($0) })
        }
        if !query.tags.isEmpty {
            clauses.append("e.tag IN (\(Self.placeholders(query.tags.count)))")
            bindings.append(contentsOf: query.tags.sorted().map { SQLValue.text($0) })
        }
        if !query.severities.isEmpty {
            clauses.append("e.severity IN (\(Self.placeholders(query.severities.count)))")
            bindings.append(contentsOf: query.severities.sorted().map { SQLValue.int(Int64($0.rawValue)) })
        }
        if !query.requiredFlags.isEmpty {
            clauses.append("(e.flags & ?) = ?")
            bindings.append(.int(Int64(query.requiredFlags.rawValue)))
            bindings.append(.int(Int64(query.requiredFlags.rawValue)))
        }

        var needsFTS = false
        if let search = query.search, !search.isEmpty {
            switch search.mode {
            case .tokens:
                needsFTS = true
                clauses.append("f.events_fts MATCH ?")
                bindings.append(.text(search.ftsExpression))
            case .substring:
                clauses.append("e.message LIKE ? ESCAPE '\\'")
                bindings.append(.text("%\(Self.escapeLike(search.text))%"))
            }
        }

        self.sql = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        self.bindings = bindings
        self.needsFTSJoin = needsFTS
    }

    static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    /// A message full of `%` and `_` is normal in a log. They are literals here.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
