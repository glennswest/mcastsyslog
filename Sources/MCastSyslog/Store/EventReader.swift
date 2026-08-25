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

    private func bind(_ bindings: [Binding], to stmt: SQLiteStatement) -> Int32 {
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
