import Foundation
import SQLite3

/// One node, as the fleet view sees it: how much it is saying, the worst thing
/// it has said lately, and when it last said anything at all.
public struct FleetNode: Identifiable, Hashable, Sendable {
    public var host: String
    public var source: String
    public var events: Int64
    public var worst: Severity
    public var lastNanos: Int64
    public var firstNanos: Int64
    /// Events per second over the window the fleet view is showing.
    public var rate: Double
    public var clockUnset: Bool
    public var malformed: Int64

    public var id: String { host }
}

/// A rollup over whatever a query matches.
public struct EventSummary: Sendable {
    public var total: Int64 = 0
    public var bySeverity: [(severity: Severity, count: Int64)] = []
    public var byHost: [(host: String, count: Int64, worst: Severity)] = []
    public var byTag: [(tag: String, count: Int64, worst: Severity)] = []
    public var malformed: Int64 = 0
    public var clockUnset: Int64 = 0
    public var collapsedRepeats: Int64 = 0
    public var rateLimited: Int64 = 0
    /// The sum of the counts on collapsed-repeat and rate-limit notices: lines
    /// the node is telling us about but did not send.
    public var linesAccountedFor: Int64 = 0
    public var firstNanos: Int64?
    public var lastNanos: Int64?

    /// Events per second over the span they actually cover.
    public var rate: Double {
        guard let first = firstNanos, let last = lastNanos, last > first else { return 0 }
        return Double(total) / (Double(last - first) / 1e9)
    }
}

/// What a query cost, so the viewer can be honest about it.
public struct QueryOutcome: Sendable {
    public var events: [LogEvent] = []
    public var scanned: Bool = false
    public var cancelled: Bool = false
    public var elapsedNanos: Int64 = 0
    /// True when the page filled to `limit` — there is more behind it.
    public var truncated: Bool = false
}

/// A read-only view of the store, with its own connection.
///
/// Its own connection is the point: a substring scan can run for a second and
/// be interrupted from another thread without disturbing the writer or any
/// other reader.
public final class EventReader: @unchecked Sendable {
    private let connection: SQLiteConnection
    private let cancelled = ManagedAtomicFlag()

    init(path: String) throws {
        self.connection = try SQLiteConnection(path: path, readOnly: true)
        try? connection.execute("PRAGMA cache_size = -16000")
    }

    /// Stop whatever this reader is doing. Safe from any thread; that is what
    /// makes "cancel" on a running scan mean something.
    public func cancel() {
        cancelled.set(true)
        connection.interrupt()
    }

    private func beginQuery() { cancelled.set(false) }

    private static let columns = """
        e.id, e.recv_ns, e.sent_ns, e.host, e.tag, e.severity, e.facility, \
        e.flags, e.repeated, e.source, e.message, e.raw
        """

    // MARK: - Pages

    /// The newest page matching the filters, oldest-first so it reads like a log.
    public func fetch(_ query: EventQuery) throws -> QueryOutcome {
        beginQuery()
        let started = Timestamp.now()
        let predicate = QueryPredicate(query)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""

        // Newest first with a LIMIT, then reversed — so the page is the tail of
        // the stream rather than its head, whatever the corpus behind it.
        let sql = """
            SELECT \(Self.columns) FROM events e \(join)
            WHERE \(predicate.sql)
            ORDER BY e.\(query.timeColumn) DESC, e.id DESC
            LIMIT ?
            """

        var outcome = QueryOutcome()
        outcome.scanned = query.requiresScan
        do {
            let stmt = try connection.prepare(sql)
            defer { stmt.finalize() }
            stmt.bind(bind(predicate.bindings, to: stmt), Int64(query.limit))

            while try stmt.step() {
                outcome.events.append(Self.decode(stmt))
            }
        } catch {
            if cancelled.value { outcome.cancelled = true } else { throw error }
        }
        outcome.events.reverse()
        outcome.truncated = outcome.events.count >= query.limit
        outcome.elapsedNanos = Timestamp.now() - started
        return outcome
    }

    /// Everything around a moment, on every node at once.
    ///
    /// This is the view that makes multicast worth having: one node's failure is
    /// usually visible in another node's log first, and neither node knows about
    /// the other.
    public func around(nanos: Int64, window: Int64, query: EventQuery) throws -> QueryOutcome {
        var q = query
        q.fromNanos = nanos - window
        q.toNanos = nanos + window
        // A wide net around the moment; the caller decides what to show of it.
        q.limit = max(query.limit, 5000)

        beginQuery()
        let started = Timestamp.now()
        let predicate = QueryPredicate(q)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""
        let sql = """
            SELECT \(Self.columns) FROM events e \(join)
            WHERE \(predicate.sql)
            ORDER BY e.\(q.timeColumn) ASC, e.id ASC
            LIMIT ?
            """

        var outcome = QueryOutcome()
        outcome.scanned = q.requiresScan
        do {
            let stmt = try connection.prepare(sql)
            defer { stmt.finalize() }
            stmt.bind(bind(predicate.bindings, to: stmt), Int64(q.limit))
            while try stmt.step() { outcome.events.append(Self.decode(stmt)) }
        } catch {
            if cancelled.value { outcome.cancelled = true } else { throw error }
        }
        outcome.truncated = outcome.events.count >= q.limit
        outcome.elapsedNanos = Timestamp.now() - started
        return outcome
    }

    /// Every matching event, streamed to `each` rather than collected — the
    /// export path, which must not need the result set in memory to write it.
    public func forEach(_ query: EventQuery, _ each: (LogEvent) throws -> Void) throws {
        beginQuery()
        let predicate = QueryPredicate(query)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""
        let sql = """
            SELECT \(Self.columns) FROM events e \(join)
            WHERE \(predicate.sql)
            ORDER BY e.\(query.timeColumn) ASC, e.id ASC
            """
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        _ = bind(predicate.bindings, to: stmt)
        while try stmt.step() {
            try each(Self.decode(stmt))
        }
    }

    // MARK: - The fleet

    /// Nodes as rows, over a window. The window is what keeps this bounded: the
    /// question is "what is this fleet doing now", not "what has it ever done".
    public func fleet(sinceNanos: Int64, ordering: TimeOrdering = .receiveTime) throws -> [FleetNode] {
        beginQuery()
        let column = ordering == .senderTime ? "event_ns" : "recv_ns"
        let sql = """
            SELECT e.host,
                   COUNT(*),
                   MIN(e.severity),
                   MAX(e.\(column)),
                   MIN(e.\(column)),
                   MAX(e.source),
                   SUM(CASE WHEN (e.flags & \(EventFlags.clockUnset.rawValue)) != 0 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN (e.flags & \(EventFlags.malformed.rawValue)) != 0 THEN 1 ELSE 0 END)
            FROM events e
            WHERE e.\(column) >= ?
            GROUP BY e.host
            ORDER BY e.host
            """
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        stmt.bind(1, sinceNanos)

        let now = Timestamp.now()
        var nodes: [FleetNode] = []
        while try stmt.step() {
            let first = stmt.int(4)
            let last = stmt.int(3)
            let count = stmt.int(1)
            // Rate over the part of the window the node was actually present
            // for, so a node that started talking ten seconds ago does not read
            // as a tenth of its real rate.
            let spanNanos = max(last - min(first, last), 1_000_000_000)
            let span = Double(min(spanNanos, now - sinceNanos)) / 1e9
            nodes.append(FleetNode(
                host: stmt.string(0),
                source: stmt.string(5),
                events: count,
                worst: Severity(clamping: Int(stmt.int(2))),
                lastNanos: last,
                firstNanos: first,
                rate: span > 0 ? Double(count) / span : 0,
                clockUnset: stmt.int(6) > 0,
                malformed: stmt.int(7)
            ))
        }
        return nodes
    }

    /// One event by id, for `/events/{id}`.
    public func event(id: Int64) throws -> LogEvent? {
        beginQuery()
        let stmt = try connection.prepare("SELECT \(Self.columns) FROM events e WHERE e.id = ?")
        defer { stmt.finalize() }
        stmt.bind(1, id)
        return try stmt.step() ? Self.decode(stmt) : nil
    }

    /// A rollup of what matches: how much, how bad, from whom, about what.
    ///
    /// Four grouped scans over the same predicate rather than one pass in
    /// Swift, because each one is an index range the database already knows how
    /// to walk, and none of them brings a row across the boundary.
    public func summary(_ query: EventQuery) throws -> EventSummary {
        beginQuery()
        let predicate = QueryPredicate(query)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""

        func grouped(_ column: String, limit: Int) throws -> [(String, Int64, Severity)] {
            let sql = """
                SELECT e.\(column), COUNT(*), MIN(e.severity) FROM events e \(join)
                WHERE \(predicate.sql)
                GROUP BY e.\(column)
                ORDER BY COUNT(*) DESC
                LIMIT ?
                """
            let stmt = try connection.prepare(sql)
            defer { stmt.finalize() }
            stmt.bind(bind(predicate.bindings, to: stmt), Int64(limit))
            var rows: [(String, Int64, Severity)] = []
            while try stmt.step() {
                rows.append((stmt.string(0), stmt.int(1), Severity(clamping: Int(stmt.int(2)))))
            }
            return rows
        }

        var summary = EventSummary()
        summary.bySeverity = try grouped("severity", limit: 8).map {
            (Severity(clamping: Int($0.0) ?? 6), $0.1)
        }
        summary.byHost = try grouped("host", limit: 200).map { ($0.0, $0.1, $0.2) }
        summary.byTag = try grouped("tag", limit: 200).map { ($0.0, $0.1, $0.2) }

        let flagsSQL = """
            SELECT COUNT(*),
                   SUM(CASE WHEN (e.flags & \(EventFlags.malformed.rawValue)) != 0 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN (e.flags & \(EventFlags.clockUnset.rawValue)) != 0 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN (e.flags & \(EventFlags.repeatNotice.rawValue)) != 0 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN (e.flags & \(EventFlags.rateLimitNotice.rawValue)) != 0 THEN 1 ELSE 0 END),
                   MIN(e.\(query.timeColumn)), MAX(e.\(query.timeColumn)),
                   COALESCE(SUM(e.repeated), 0)
            FROM events e \(join)
            WHERE \(predicate.sql)
            """
        let stmt = try connection.prepare(flagsSQL)
        defer { stmt.finalize() }
        _ = bind(predicate.bindings, to: stmt)
        if try stmt.step() {
            summary.total = stmt.int(0)
            summary.malformed = stmt.int(1)
            summary.clockUnset = stmt.int(2)
            summary.collapsedRepeats = stmt.int(3)
            summary.rateLimited = stmt.int(4)
            summary.firstNanos = stmt.intOrNil(5)
            summary.lastNanos = stmt.intOrNil(6)
            // What the node held back or collapsed. Lines that exist and are not
            // here, which is worth stating rather than leaving to be inferred
            // from a gap.
            summary.linesAccountedFor = stmt.int(7)
        }
        return summary
    }

    /// Every host ever heard from, whether or not it is talking now. A node that
    /// has gone silent is exactly the one worth being able to select.
    public func knownHosts() throws -> [String] {
        try strings("SELECT host FROM hosts ORDER BY host")
    }

    public func knownTags() throws -> [String] {
        try strings("SELECT tag FROM tags ORDER BY tag")
    }

    private func strings(_ sql: String) throws -> [String] {
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        var out: [String] = []
        while try stmt.step() { out.append(stmt.string(0)) }
        return out
    }

    /// How many events match, for the "showing 3000 of N" line. Bounded by
    /// `ceiling` so this never becomes a full scan just to render a number.
    public func countMatching(_ query: EventQuery, ceiling: Int = 200_000) throws -> (count: Int64, exact: Bool) {
        beginQuery()
        let predicate = QueryPredicate(query)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""
        let sql = """
            SELECT COUNT(*) FROM (
                SELECT e.id FROM events e \(join) WHERE \(predicate.sql) LIMIT ?
            )
            """
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        stmt.bind(bind(predicate.bindings, to: stmt), Int64(ceiling + 1))
        guard try stmt.step() else { return (0, true) }
        let n = stmt.int(0)
        return n > Int64(ceiling) ? (Int64(ceiling), false) : (n, true)
    }

    // MARK: - Plumbing

    private func bind(_ bindings: [SQLValue], to stmt: SQLiteStatement) -> Int32 {
        var index: Int32 = 1
        for binding in bindings {
            switch binding {
            case .int(let v): stmt.bind(index, v)
            case .text(let v): stmt.bind(index, v)
            }
            index += 1
        }
        return index
    }

    static func decode(_ stmt: SQLiteStatement) -> LogEvent {
        LogEvent(
            id: stmt.int(0),
            recvNanos: stmt.int(1),
            sentNanos: stmt.intOrNil(2),
            host: stmt.string(3),
            tag: stmt.string(4),
            severity: Severity(clamping: Int(stmt.int(5))),
            facility: UInt8(clamping: stmt.int(6)),
            flags: EventFlags(rawValue: Int32(truncatingIfNeeded: stmt.int(7))),
            repeated: stmt.intOrNil(8).map(Int.init),
            source: stmt.string(9),
            message: stmt.string(10),
            raw: stmt.data(11)
        )
    }
}

/// A boolean that `cancel` sets from one thread and the query loop reads from
/// another. Touched once at the start of a query and once when it is
/// cancelled, so a lock costs nothing worth measuring here.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock(); storage = newValue; lock.unlock()
    }
}
