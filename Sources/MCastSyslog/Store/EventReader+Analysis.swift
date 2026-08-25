import Foundation

extension EventReader {

    /// Read a whole sequence.
    ///
    /// Every part of this is a bounded, grouped query: nothing walks the corpus
    /// row by row in Swift, and nothing brings back more than it reports. An
    /// analysis that cost more than the thing it is analysing would not get run
    /// when it was needed.
    public func analyse(
        from fromNanos: Int64,
        to toNanos: Int64,
        hosts: Set<String> = [],
        policy: LifecyclePolicy = .default,
        rateBuckets: Int = 60,
        correlationWindowNanos: Int64 = 5_000_000_000,
        maxCorrelations: Int = 5,
        alignToRun: Bool = true
    ) throws -> SequenceAnalysis {
        var fromNanos = fromNanos

        // "The whole sequence" means the run, not the arbitrary span someone
        // happened to ask for. When one node is named and it booted inside the
        // window, start at the boot — otherwise the analysis measures a startup
        // phase from a moment the node was not yet running, which is what it
        // did the first time this ran against a real fleet.
        if alignToRun, hosts.count == 1 {
            // Only `.boot` starts a run. A clock reset mid-run is not a
            // reboot — a node running ntpd steps its clock whenever the
            // upstream drifts, and treating that as a boot snapped the window
            // to a 35-second ntpd adjustment and analysed two events.
            // Anchoring is a different question from segmenting. For segmenting,
            // stated and inferred boots both count. For choosing *the* boot to
            // start at, a stated one wins outright when the window has any: a
            // node that logs sporadically produces inferred boots wherever it
            // was quiet, and anchoring on the latest of those landed on an ntpd
            // adjustment with two events after it while the real boot — which
            // the kernel had announced — sat half an hour earlier.
            //
            // Asked as its own query rather than by running the whole lifecycle
            // scan: at three quarters of a million events that scan took eight
            // seconds, and this takes a third of one.
            if let stated = try latestStatedBoot(from: fromNanos, to: toNanos, host: hosts.first!) {
                fromNanos = stated
            } else if let inferred = try latestInferredBoot(
                from: fromNanos, to: toNanos, host: hosts.first!, gap: policy.gapNanos) {
                fromNanos = inferred
            }
        }

        var analysis = SequenceAnalysis()
        analysis.fromNanos = fromNanos
        analysis.toNanos = toNanos
        analysis.alignedToRun = alignToRun && hosts.count == 1

        let hostClause = hosts.isEmpty ? "" : "AND host IN (\(QueryPredicate.placeholders(hosts.count)))"

        /// Every query here shares the same window and host restriction.
        func bindWindow(_ stmt: SQLiteStatement, from index: Int32 = 1) -> Int32 {
            var next = index
            stmt.bind(next, fromNanos); next += 1
            stmt.bind(next, toNanos); next += 1
            for host in hosts.sorted() { stmt.bind(next, host); next += 1 }
            return next
        }

        // MARK: Totals and flags

        do {
            let stmt = try prepare("""
                SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN (flags & \(EventFlags.malformed.rawValue)) != 0 THEN 1 ELSE 0 END), 0),
                       COALESCE(SUM(CASE WHEN (flags & \(EventFlags.clockUnset.rawValue)) != 0 THEN 1 ELSE 0 END), 0),
                       COALESCE(SUM(repeated), 0)
                FROM events WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
                """)
            defer { stmt.finalize() }
            _ = bindWindow(stmt)
            if try stmt.step() {
                analysis.totalEvents = stmt.int(0)
                analysis.malformed = stmt.int(1)
                analysis.clockUnset = stmt.int(2)
                analysis.linesHeldBack = stmt.int(3)
            }
        }

        guard analysis.totalEvents > 0 else { return analysis }

        // MARK: Who is in it

        do {
            let stmt = try prepare("""
                SELECT DISTINCT host FROM events
                WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause) ORDER BY host
                """)
            defer { stmt.finalize() }
            _ = bindWindow(stmt)
            while try stmt.step() { analysis.hosts.append(stmt.string(0)) }
        }

        // MARK: Workload debuts — the order things came up in

        do {
            let stmt = try prepare("""
                SELECT tag, MIN(recv_ns), MAX(recv_ns), COUNT(*), MIN(severity)
                FROM events WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
                GROUP BY tag ORDER BY MIN(recv_ns)
                """)
            defer { stmt.finalize() }
            _ = bindWindow(stmt)
            while try stmt.step() {
                let first = stmt.int(1)
                analysis.debuts.append(SequenceAnalysis.Debut(
                    tag: stmt.string(0),
                    firstNanos: first,
                    offsetNanos: first - fromNanos,
                    lastNanos: stmt.int(2),
                    events: stmt.int(3),
                    worst: Severity(clamping: Int(stmt.int(4)))))
            }
        }

        // MARK: Escalations — the first time it got worse, at each level

        for severity in [Severity.warning, .error, .critical, .alert, .emergency] {
            let stmt = try prepare("""
                SELECT id, recv_ns, sent_ns, host, tag, message FROM events
                WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause) AND severity = ?
                ORDER BY id LIMIT 1
                """)
            defer { stmt.finalize() }
            let next = bindWindow(stmt)
            stmt.bind(next, Int64(severity.rawValue))
            if try stmt.step() {
                let at = stmt.intOrNil(2) ?? stmt.int(1)
                analysis.escalations.append(SequenceAnalysis.Escalation(
                    severity: severity, atNanos: at, offsetNanos: stmt.int(1) - fromNanos,
                    host: stmt.string(3), tag: stmt.string(4), message: stmt.string(5),
                    eventId: stmt.int(0)))
            }
        }
        // Worst first: the first emergency matters more than the first warning.
        analysis.escalations.sort { $0.severity.rawValue < $1.severity.rawValue }

        // MARK: Gaps — where the time went

        do {
            // Only `host` and `recv_ns` are selected, and only those are ordered
            // by, so the whole walk is served out of the index on
            // (host, recv_ns, id) without reading a single row. Selecting the
            // message here as well — which is what this did first — forced a
            // row lookup for every event in the window and cost ten times as
            // much for ten rows of output.
            let stmt = try prepare("""
                WITH walked AS (
                    SELECT host, recv_ns, LAG(recv_ns) OVER w AS prev_recv
                    FROM events
                    WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
                    WINDOW w AS (PARTITION BY host ORDER BY recv_ns, id)
                )
                SELECT host, prev_recv, recv_ns
                FROM walked
                WHERE prev_recv IS NOT NULL AND recv_ns - prev_recv > ?
                ORDER BY recv_ns - prev_recv DESC
                LIMIT 10
                """)
            defer { stmt.finalize() }
            let next = bindWindow(stmt)
            // Anything shorter than a second is the fleet breathing, not a gap.
            stmt.bind(next, Int64(1_000_000_000))
            while try stmt.step() {
                analysis.gaps.append(SequenceAnalysis.Gap(
                    afterNanos: stmt.int(1), untilNanos: stmt.int(2),
                    host: stmt.string(0), lastMessage: ""))
            }
        }

        // Now fetch the line before each of the ten, which is what the node was
        // doing while it was quiet.
        for index in analysis.gaps.indices {
            let stmt = try prepare("""
                SELECT message FROM events
                WHERE host = ? AND recv_ns = ? ORDER BY id DESC LIMIT 1
                """)
            defer { stmt.finalize() }
            stmt.bind(1, analysis.gaps[index].host)
            stmt.bind(2, analysis.gaps[index].afterNanos)
            if try stmt.step() { analysis.gaps[index].lastMessage = stmt.string(0) }
        }

        // MARK: The shape of it

        let bucketNanos = max(1_000_000_000, (toNanos - fromNanos) / Int64(max(1, rateBuckets)))
        do {
            let stmt = try prepare("""
                SELECT (recv_ns - ?) / ?, COUNT(*), MIN(severity)
                FROM events WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause)
                GROUP BY 1 ORDER BY 1
                """)
            defer { stmt.finalize() }
            stmt.bind(1, fromNanos)
            stmt.bind(2, bucketNanos)
            var next: Int32 = 3
            stmt.bind(next, fromNanos); next += 1
            stmt.bind(next, toNanos); next += 1
            for host in hosts.sorted() { stmt.bind(next, host); next += 1 }
            while try stmt.step() {
                analysis.rateProfile.append(SequenceAnalysis.RateSample(
                    startNanos: fromNanos + stmt.int(0) * bucketNanos,
                    events: stmt.int(1),
                    worst: Severity(clamping: Int(stmt.int(2)))))
            }
        }

        // MARK: Clock skew at the ends

        do {
            // Ordered by recv_ns rather than id: both are arrival order, but
            // only one of them is the index's own order, and sorting by the
            // other built a temp b-tree over the whole window.
            for (isStart, column) in [(true, "ASC"), (false, "DESC")] {
                let stmt = try prepare("""
                    SELECT recv_ns - sent_ns FROM events
                    WHERE recv_ns >= ? AND recv_ns <= ? \(hostClause) AND sent_ns IS NOT NULL
                    ORDER BY recv_ns \(column) LIMIT 1
                    """)
                defer { stmt.finalize() }
                _ = bindWindow(stmt)
                if try stmt.step() {
                    if isStart { analysis.skewStartNanos = stmt.int(0) }
                    else { analysis.skewEndNanos = stmt.int(0) }
                }
            }
        }

        analysis.phases = try phases(for: analysis, policy: policy, hostClause: hostClause, hosts: hosts)
        analysis.findings = findings(for: analysis, bucketNanos: bucketNanos)
        analysis.correlations = try correlations(
            for: analysis, windowNanos: correlationWindowNanos, limit: maxCorrelations)
        return analysis
    }

    // MARK: - Segmentation

    private func phases(
        for analysis: SequenceAnalysis,
        policy: LifecyclePolicy,
        hostClause: String,
        hosts: Set<String>
    ) throws -> [SequenceAnalysis.Phase] {
        // Phases describe one node coming up and running. A window holding
        // several nodes has several such sequences overlaid, and calling their
        // union "startup" would be a statement about nothing. Scoping to a host
        // is what makes the question answerable.
        guard analysis.hosts.count == 1 else { return [] }

        var phases: [SequenceAnalysis.Phase] = []
        var cursor = analysis.fromNanos

        /// Counted rather than summed from the rate buckets: a bucket boundary
        /// does not fall on a phase boundary, and a phase reporting zero events
        /// because of arithmetic is worse than one that costs a query.
        func measure(_ from: Int64, _ to: Int64) throws -> (events: Int64, worst: Severity) {
            let stmt = try prepare("""
                SELECT COUNT(*), COALESCE(MIN(severity), 6) FROM events
                WHERE recv_ns >= ? AND recv_ns < ? \(hostClause)
                """)
            defer { stmt.finalize() }
            var index: Int32 = 1
            stmt.bind(index, from); index += 1
            stmt.bind(index, to); index += 1
            for host in hosts.sorted() { stmt.bind(index, host); index += 1 }
            guard try stmt.step() else { return (0, .info) }
            return (stmt.int(0), Severity(clamping: Int(stmt.int(1))))
        }

        // Before the clock came up. The node sends the nil timestamp until NTP
        // syncs in the initramfs, so this boundary is the initramfs ending.
        if analysis.clockUnset > 0, let firstClocked = analysis.debuts.map(\.firstNanos).min() {
            let end = analysis.skewStartNanos != nil ? firstClocked : analysis.toNanos
            if end > cursor {
                let measured = try measure(cursor, end)
                phases.append(.init(kind: .preClock, startNanos: cursor, endNanos: end,
                                    events: analysis.clockUnset, worst: measured.worst,
                                    note: "Frames carrying the nil timestamp: the node had not synced NTP yet. Ordered by when they were heard."))
                cursor = end
            }
        }

        // Coming up: workloads still appearing for the first time.
        //
        // Startup ends where the debuts stop arriving in a run, not at the last
        // debut of any kind. A tag that appears once, twenty minutes after
        // everything else, is not the system still starting up — and counting
        // it stretched "startup" across the whole window when this first ran
        // against a real fleet.
        //
        // Size was the wrong test for that: on a small window a single line can
        // be one percent of the traffic, and on a large one a workload that
        // matters can be a fraction of a percent. What actually separates them
        // is time — a debut that arrives long after the previous one has
        // nothing to do with coming up.
        let substantial = Self.debutsBelongingToStartup(analysis.debuts)
        if let lastDebut = substantial.map(\.firstNanos).max(), lastDebut > cursor {
            let measured = try measure(cursor, lastDebut)
            let late = analysis.debuts.count - substantial.count
            phases.append(.init(kind: .startup, startNanos: cursor, endNanos: lastDebut,
                                events: measured.events, worst: measured.worst,
                                note: "Workloads still appearing for the first time — \(substantial.count) of them by the end of this."
                                    + (late > 0 ? " \(late) more appeared later, too briefly to count as the system still starting." : "")))
            cursor = lastDebut
        }

        // The first fault splits what is left.
        let firstFault = analysis.escalations.first { $0.severity.rawValue <= Severity.error.rawValue }
        if let fault = firstFault, fault.atNanos > cursor {
            let before = try measure(cursor, fault.atNanos)
            let after = try measure(fault.atNanos, analysis.toNanos)
            phases.append(.init(kind: .steady, startNanos: cursor, endNanos: fault.atNanos,
                                events: before.events, worst: before.worst,
                                note: "The set of workloads had stopped changing and nothing had gone wrong yet."))
            phases.append(.init(kind: .degraded, startNanos: fault.atNanos, endNanos: analysis.toNanos,
                                events: after.events, worst: after.worst,
                                note: "From the first \(fault.severity.label) onwards: \(PlainText.strip(fault.message))"))
        } else if analysis.toNanos > cursor {
            let measured = try measure(cursor, analysis.toNanos)
            phases.append(.init(kind: .steady, startNanos: cursor, endNanos: analysis.toNanos,
                                events: measured.events, worst: measured.worst,
                                note: "The set of workloads had stopped changing."))
        }
        return phases
    }

    /// The most recent boot the kernel announced, if there was one in the window.
    ///
    /// A scan of the host's own rows rather than an FTS lookup, which is
    /// counter-intuitive but measured: `Linux version` appears in every boot of
    /// every node, so the FTS posting list is enormous and carries no time or
    /// host dimension to narrow it by. Going through the index on
    /// `(host, recv_ns, id)` and testing the handful of rows in range took a
    /// third of a second where FTS took eighteen.
    func latestStatedBoot(from fromNanos: Int64, to toNanos: Int64, host: String) throws -> Int64? {
        let stmt = try prepare("""
            SELECT recv_ns FROM events
            WHERE host = ? AND recv_ns > ? AND recv_ns < ? AND message LIKE 'Linux version %'
            ORDER BY recv_ns DESC LIMIT 1
            """)
        defer { stmt.finalize() }
        stmt.bind(1, host)
        stmt.bind(2, fromNanos)
        stmt.bind(3, toNanos)
        return try stmt.step() ? stmt.int(0) : nil
    }

    /// The last silence long enough to have been a restart.
    ///
    /// The fallback for a node whose kernel banner is not in the window. Like
    /// the gaps query, it selects only the columns the index already holds, so
    /// it never reads a row. Running the whole lifecycle scan for this instead
    /// made a thirty-minute window slower to analyse than a whole day's.
    func latestInferredBoot(from fromNanos: Int64, to toNanos: Int64, host: String, gap: Int64) throws -> Int64? {
        let stmt = try prepare("""
            WITH walked AS (
                SELECT recv_ns, LAG(recv_ns) OVER (ORDER BY recv_ns, id) AS prev_recv
                FROM events
                WHERE host = ? AND recv_ns >= ? AND recv_ns <= ?
            )
            SELECT recv_ns FROM walked
            WHERE prev_recv IS NOT NULL AND recv_ns - prev_recv > ?
            ORDER BY recv_ns DESC LIMIT 1
            """)
        defer { stmt.finalize() }
        stmt.bind(1, host)
        stmt.bind(2, fromNanos)
        stmt.bind(3, toNanos)
        stmt.bind(4, gap)
        return try stmt.step() ? stmt.int(0) : nil
    }

    /// The leading run of debuts that arrive close enough together to be one
    /// system coming up.
    ///
    /// Each debut extends the run if it lands within a grace period of the last
    /// one — sixty seconds, or three times however long startup has taken so
    /// far, whichever is longer. The second term matters: a node that takes two
    /// minutes to bring up its storage should not have the next workload judged
    /// against the same window as one that took two seconds.
    static func debutsBelongingToStartup(
        _ debuts: [SequenceAnalysis.Debut]
    ) -> [SequenceAnalysis.Debut] {
        let ordered = debuts.sorted { $0.firstNanos < $1.firstNanos }
        guard let first = ordered.first else { return [] }

        var kept = [first]
        for debut in ordered.dropFirst() {
            let elapsed = kept.last!.firstNanos - first.firstNanos
            let grace = max(60_000_000_000, elapsed * 3)
            guard debut.firstNanos - kept.last!.firstNanos <= grace else { break }
            kept.append(debut)
        }
        return kept
    }

    // MARK: - What was unusual

    private func findings(for analysis: SequenceAnalysis, bucketNanos: Int64) -> [SequenceAnalysis.Finding] {
        var findings: [SequenceAnalysis.Finding] = []

        // A large skew that shrinks fast is a node replaying a boot's backlog.
        // The spec is explicit that this is correct behaviour, so the analysis
        // names it rather than letting it read as a fault.
        if let start = analysis.skewStartNanos, let end = analysis.skewEndNanos,
           start > 30_000_000_000, start - end > start / 2 {
            findings.append(.init(
                title: "A backlog was replayed",
                detail: "Sender and receive times start \(Timestamp.formatInterval(start)) apart and end "
                    + "\(Timestamp.formatInterval(end)) apart. That is a node sending a boot's worth of "
                    + "lines once its network came up — correct behaviour, not a fault.",
                confidence: .observed, atNanos: analysis.fromNanos, host: analysis.hosts.first))
        }

        if analysis.clockUnset > 0 {
            findings.append(.init(
                title: "Part of this happened before the clock was real",
                detail: "\(analysis.clockUnset.formatted()) events carry the nil timestamp. The node syncs NTP "
                    + "in the initramfs precisely so its times are real; when it could not, it said so rather "
                    + "than inventing one. Those events are ordered by receive time.",
                confidence: .stated, atNanos: analysis.fromNanos, host: nil))
        }

        if analysis.linesHeldBack > 0 {
            findings.append(.init(
                title: "\(analysis.linesHeldBack.formatted()) lines never reached the wire",
                detail: "The nodes collapsed repeats and rate-limited themselves, and said how much they held "
                    + "back. Those lines are in the nodes' own files; `must-gather` would still collect them.",
                confidence: .stated, atNanos: nil, host: nil))
        }

        if analysis.hosts.contains("(none)") {
            findings.append(.init(
                title: "Something is emitting before its hostname is set",
                detail: "Events arrived from a host calling itself `(none)`, which is what Linux reports "
                    + "before the hostname has been configured. That is early boot — those lines come "
                    + "from before the node knew what it was called. Look at the `source` address to "
                    + "tell which machine they were.",
                confidence: .observed, atNanos: nil, host: "(none)"))
        }

        if analysis.malformed > 0 {
            findings.append(.init(
                title: "\(analysis.malformed.formatted()) frames did not parse",
                detail: "Kept verbatim rather than dropped. Something is emitting to the group that is not "
                    + "sending RFC 5424 — worth looking at, because a viewer that hid these would be hiding "
                    + "exactly the interesting failure.",
                confidence: .observed, atNanos: nil, host: nil))
        }

        // A burst well above the run's own baseline.
        if analysis.rateProfile.count >= 4 {
            let counts = analysis.rateProfile.map { Double($0.events) }
            let median = counts.sorted()[counts.count / 2]
            if let peak = analysis.rateProfile.max(by: { $0.events < $1.events }),
               median > 0, Double(peak.events) > max(median * 5, median + 20) {
                findings.append(.init(
                    title: "A burst well above this window's own rate",
                    detail: "\(peak.events.formatted()) events in one "
                        + "\(Timestamp.formatInterval(bucketNanos)) bucket at "
                        + "\(Timestamp.format(peak.startNanos, style: .timeOnly)), against a median of "
                        + "\(Int(median)). Either something started repeating itself, or a node replayed a backlog.",
                    confidence: .observed, atNanos: peak.startNanos, host: nil))
            }
        }

        // Everything went quiet and stayed quiet.
        if let last = analysis.rateProfile.last, last.startNanos + bucketNanos * 2 < analysis.toNanos {
            findings.append(.init(
                title: "The window ends in silence",
                detail: "Nothing was heard for the last "
                    + "\(Timestamp.formatInterval(analysis.toNanos - last.startNanos)) of this window. "
                    + "A node that stopped talking and a node that had nothing to say look the same from "
                    + "here; the lifecycle view distinguishes them by what was said last.",
                confidence: .suggested, atNanos: last.startNanos, host: nil))
        }

        return findings
    }

    // MARK: - What everyone else was saying

    private func correlations(
        for analysis: SequenceAnalysis,
        windowNanos: Int64,
        limit: Int
    ) throws -> [SequenceAnalysis.Correlation] {
        let faults = analysis.escalations
            .filter { $0.severity.rawValue <= Severity.error.rawValue }
            .prefix(limit)
        guard !faults.isEmpty, analysis.hosts.count > 1 else { return [] }

        var correlations: [SequenceAnalysis.Correlation] = []
        for fault in faults {
            let stmt = try prepare("""
                SELECT \(EventReader.columns) FROM events e
                WHERE e.recv_ns >= ? AND e.recv_ns <= ? AND e.host != ? AND e.severity <= ?
                ORDER BY e.id LIMIT 25
                """)
            defer { stmt.finalize() }
            stmt.bind(1, fault.atNanos - windowNanos)
            stmt.bind(2, fault.atNanos + windowNanos)
            stmt.bind(3, fault.host)
            stmt.bind(4, Int64(Severity.warning.rawValue))

            var elsewhere: [LogEvent] = []
            while try stmt.step() { elsewhere.append(EventReader.decode(stmt)) }
            guard !elsewhere.isEmpty else { continue }

            correlations.append(SequenceAnalysis.Correlation(
                faultId: fault.eventId, faultHost: fault.host, faultMessage: fault.message,
                atNanos: fault.atNanos, windowSeconds: Double(windowNanos) / 1e9,
                elsewhere: elsewhere))
        }
        return correlations
    }
}
