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

    /// Prepare a statement on this reader's own connection. Used by the
    /// analysis extension, which is a separate file for length rather than
    /// because it is a separate thing.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        try connection.prepare(sql)
    }

    static let columns = """
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

    /// The oldest matching events after a cursor, in arrival order.
    ///
    /// Ordered by id rather than by either timestamp: a cursor has to be over
    /// something monotonic at the viewer, and a node's clock is not. An event
    /// that arrives late still gets a higher id than everything already
    /// returned, so a tail built on this cannot skip it.
    public func fetchForward(_ query: EventQuery) throws -> QueryOutcome {
        beginQuery()
        let started = Timestamp.now()
        let predicate = QueryPredicate(query)
        let join = predicate.needsFTSJoin ? "JOIN events_fts f ON f.rowid = e.id" : ""
        let sql = """
            SELECT \(Self.columns) FROM events e \(join)
            WHERE \(predicate.sql)
            ORDER BY e.id ASC
            LIMIT ?
            """

        var outcome = QueryOutcome()
        outcome.scanned = query.requiresScan
        do {
            let stmt = try connection.prepare(sql)
            defer { stmt.finalize() }
            stmt.bind(bind(predicate.bindings, to: stmt), Int64(query.limit))
            while try stmt.step() { outcome.events.append(Self.decode(stmt)) }
        } catch {
            if cancelled.value { outcome.cancelled = true } else { throw error }
        }
        outcome.truncated = outcome.events.count >= query.limit
        outcome.elapsedNanos = Timestamp.now() - started
        return outcome
    }

    /// The newest id in the store, so a tail can start from "now" rather than
    /// from the beginning of history.
    public func newestId() throws -> Int64 {
        beginQuery()
        let stmt = try connection.prepare("SELECT COALESCE(MAX(id), 0) FROM events")
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.int(0) : 0
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

    // MARK: - Lifecycle

    /// Where each node's runs begin and end, and what it said at the seams.
    ///
    /// The boundary detection is done in SQL with a window function rather than
    /// by walking every row in Swift: the interesting rows are a tiny fraction
    /// of the corpus, and there is no reason to carry the rest across the
    /// boundary to throw away.
    public func lifecycle(
        from fromNanos: Int64,
        to toNanos: Int64,
        hosts: Set<String> = [],
        policy: LifecyclePolicy = .default,
        ceiling: Int = 5000
    ) throws -> LifecycleReport {
        beginQuery()
        var report = LifecycleReport(fromNanos: fromNanos, toNanos: toNanos)

        var hostClause = ""
        if !hosts.isEmpty {
            hostClause = "AND host IN (\(QueryPredicate.placeholders(hosts.count)))"
        }

        // `prev_*` are the same node's previous event in arrival order. Arrival
        // order, not either timestamp: it is the only ordering a node with a
        // wrong clock cannot perturb, and a boot is precisely the moment a
        // node's clock is least trustworthy.
        let sql = """
            WITH walked AS (
                SELECT id, host, recv_ns, sent_ns, severity, flags, message,
                       LAG(recv_ns) OVER w AS prev_recv,
                       LAG(sent_ns) OVER w AS prev_sent,
                       LAG(flags)   OVER w AS prev_flags
                FROM events
                WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
                WINDOW w AS (PARTITION BY host ORDER BY id)
            )
            SELECT id, host, recv_ns, sent_ns, severity, message, flags, prev_recv, prev_sent, prev_flags
            FROM walked
            WHERE prev_recv IS NULL
               OR recv_ns - prev_recv > ?
               OR (sent_ns IS NOT NULL AND prev_sent IS NOT NULL AND prev_sent - sent_ns > ?)
               OR ((prev_flags & \(EventFlags.clockUnset.rawValue)) != 0
                   AND (flags & \(EventFlags.clockUnset.rawValue)) = 0)
               OR severity <= \(Severity.critical.rawValue)
               OR message LIKE 'Linux version %'
            ORDER BY id
            LIMIT ?
            """

        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        var index: Int32 = 1
        stmt.bind(index, fromNanos); index += 1
        stmt.bind(index, toNanos); index += 1
        for host in hosts.sorted() { stmt.bind(index, host); index += 1 }
        stmt.bind(index, policy.gapNanos); index += 1
        stmt.bind(index, policy.clockBackstepNanos); index += 1
        stmt.bind(index, Int64(ceiling + 1))

        while try stmt.step() {
            let id = stmt.int(0)
            let host = stmt.string(1)
            let recv = stmt.int(2)
            let sent = stmt.intOrNil(3)
            let severity = Severity(clamping: Int(stmt.int(4)))
            let message = stmt.string(5)
            let flags = EventFlags(rawValue: Int32(truncatingIfNeeded: stmt.int(6)))
            let previousRecv = stmt.intOrNil(7)
            let previousSent = stmt.intOrNil(8)
            let previousFlags = stmt.intOrNil(9).map { EventFlags(rawValue: Int32(truncatingIfNeeded: $0)) }

            if report.markers.count >= ceiling {
                report.truncated = true
                break
            }

            // A row can satisfy more than one condition — the first frame of a
            // boot is often also the frame that has no clock. Classified in the
            // order that says the most about what happened.
            let marker: LifecycleMarker
            var stated = false
            var gap: Int64?
            if message.hasPrefix("Linux version ") {
                // The kernel says so. Nothing inferred beats that.
                marker = .kernelBoot
                stated = true
                if let previousRecv { gap = recv - previousRecv }
            } else if previousRecv == nil {
                marker = .boot
            } else if let previousRecv, recv - previousRecv > policy.gapNanos {
                marker = .boot
                gap = recv - previousRecv
            } else if let previousSent, let sent, previousSent - sent > policy.clockBackstepNanos {
                marker = .clockReset
            } else if previousFlags?.contains(.clockUnset) == true, !flags.contains(.clockUnset) {
                marker = .clockSync
            } else {
                marker = .fault
            }

            report.markers.append(LifecycleEvent(
                id: id, marker: marker, stated: stated, host: host, recvNanos: recv,
                sentNanos: sent, severity: severity, message: message, gapNanos: gap))
        }

        report.runs = try runs(from: fromNanos, to: toNanos, hosts: hosts,
                               policy: policy, markers: report.markers)
        return report
    }

    /// Merge stated and inferred boot markers into one set of run boundaries.
    ///
    /// Both are kept: a stated boot does not mean the inferred ones elsewhere
    /// in the stream were wrong, and dropping them merged six restarts of one
    /// node into a single run. What has to be avoided is counting the *same*
    /// boot twice — the kernel banner and the first line of userspace arrive
    /// milliseconds apart — so boundaries close together collapse to one, and
    /// the stated one wins.
    static func coalesceBoots(_ markers: [LifecycleEvent], within nanos: Int64 = 5_000_000_000) -> [Int64] {
        let boots = markers.filter(\.startsARun).sorted { $0.recvNanos < $1.recvNanos }
        var kept: [(nanos: Int64, stated: Bool)] = []
        for boot in boots {
            if let last = kept.last, boot.recvNanos - last.nanos <= nanos {
                if boot.stated, !last.stated { kept[kept.count - 1] = (boot.recvNanos, true) }
                continue
            }
            kept.append((boot.recvNanos, boot.stated))
        }
        return kept.map(\.nanos)
    }

    /// Turn the boundaries into runs, and say how each one ended.
    private func runs(
        from fromNanos: Int64,
        to toNanos: Int64,
        hosts: Set<String>,
        policy: LifecyclePolicy,
        markers: [LifecycleEvent]
    ) throws -> [NodeRun] {
        let now = Timestamp.now()
        var byHost: [String: [LifecycleEvent]] = [:]
        for marker in markers { byHost[marker.host, default: []].append(marker) }

        var hostRows: [(host: String, first: Int64, last: Int64, count: Int64, worst: Severity)] = []
        var hostClause = ""
        if !hosts.isEmpty { hostClause = "AND host IN (\(QueryPredicate.placeholders(hosts.count)))" }
        let stmt = try connection.prepare("""
            SELECT host, MIN(recv_ns), MAX(recv_ns), COUNT(*), MIN(severity)
            FROM events WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
            GROUP BY host
            """)
        defer { stmt.finalize() }
        var index: Int32 = 1
        stmt.bind(index, fromNanos); index += 1
        stmt.bind(index, toNanos); index += 1
        for host in hosts.sorted() { stmt.bind(index, host); index += 1 }
        while try stmt.step() {
            hostRows.append((stmt.string(0), stmt.int(1), stmt.int(2), stmt.int(3),
                             Severity(clamping: Int(stmt.int(4)))))
        }

        var runs: [NodeRun] = []
        for row in hostRows {
            // A run begins at a boot. A clock reset is worth marking — the
            // node's sense of time changed underneath it — but a node running
            // ntpd steps its clock in the middle of a perfectly healthy run,
            // and splitting the run there would invent a reboot that did not
            // happen.
            let hostMarkers = byHost[row.host] ?? []
            let boundaries = Self.coalesceBoots(hostMarkers)
            // The first event of the window and the first boot in it are the
            // same moment seen twice when the window opens on a boot, so they
            // are collapsed the same way boundaries are — otherwise the report
            // opens with a run zero seconds long.
            let starts = ([row.first] + boundaries).sorted().reduce(into: [Int64]()) { unique, value in
                if let last = unique.last, value - last <= 5_000_000_000 { return }
                unique.append(value)
            }

            let statedStarts = Set(hostMarkers.filter { $0.marker == .kernelBoot }.map(\.recvNanos))

            for (position, start) in starts.enumerated() {
                let end = position + 1 < starts.count ? starts[position + 1] : row.last
                let markersInRun = (byHost[row.host] ?? [])
                    .filter { $0.recvNanos >= start && $0.recvNanos <= end }
                let faults = markersInRun.filter { $0.marker == .fault }.count
                let isLast = position + 1 == starts.count
                let silence = now - end

                // A run's ending is only knowable for the last one; every
                // earlier run ended because a new one started, which says
                // nothing about how.
                let ending: RunEnding
                if !isLast {
                    let nextStart = starts[position + 1]
                    if markersInRun.last?.marker == .fault {
                        // It was saying something was wrong, and then it
                        // restarted. That ordering is worth keeping.
                        ending = .faulted
                    } else if statedStarts.contains(nextStart) {
                        // The kernel announced the next boot, so this run ended
                        // in a restart rather than merely stopping.
                        ending = .rebooted
                    } else {
                        ending = .cutOff
                    }
                } else if silence < policy.gapNanos {
                    ending = .running
                } else if markersInRun.last?.marker == .fault {
                    ending = .faulted
                } else {
                    let span = max(Double(end - start) / 1e9, 1)
                    let rate = Double(row.count) / span
                    ending = rate >= policy.busyRatePerSecond ? .cutOff : .quiet
                }

                runs.append(NodeRun(
                    host: row.host,
                    startNanos: start,
                    lastNanos: end,
                    events: isLast ? row.count : 0,
                    worst: markersInRun.map(\.severity).min() ?? row.worst,
                    ending: ending,
                    startedWithoutAClock: markersInRun.contains { $0.marker == .clockSync }
                        || markersInRun.first?.sentNanos == nil,
                    clockSyncNanos: markersInRun.first { $0.marker == .clockSync }?.recvNanos,
                    faults: Int64(faults)
                ))
            }
        }
        return runs.sorted { ($0.host, $0.startNanos) < ($1.host, $1.startNanos) }
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
