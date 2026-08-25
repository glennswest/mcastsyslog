import XCTest
@testable import MCastSyslog

final class EventStoreTests: XCTestCase {

    private var directory: URL!
    private var store: EventStore!
    private var reader: EventReader!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcastsyslog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try EventStore(path: directory.appendingPathComponent("events.sqlite3").path)
        reader = try store.makeReader()
    }

    override func tearDownWithError() throws {
        reader = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private let base: Int64 = 1_787_000_000_000_000_000

    @discardableResult
    private func insert(
        _ count: Int,
        host: String = "storm-01",
        tag: String = "stormblock",
        severity: Severity = .info,
        flags: EventFlags = [],
        startingAt offset: Int64 = 0,
        spacingNanos: Int64 = 1_000_000,
        message: (Int) -> String = { "line \($0)" }
    ) throws -> [LogEvent] {
        let events = (0..<count).map { i in
            LogEvent(
                recvNanos: base + offset + Int64(i) * spacingNanos,
                sentNanos: base + offset + Int64(i) * spacingNanos - 1_000_000,
                host: host, tag: tag, severity: severity, flags: flags,
                source: "203.0.113.1", message: message(i)
            )
        }
        try store.insert(events)
        return events
    }

    private func query(_ build: (inout FilterState) -> Void = { _ in }) -> EventQuery {
        var filter = FilterState()
        build(&filter)
        var q = filter.query(ordering: .senderTime, limit: 1000, now: base + 1_000_000_000_000)
        q.fromNanos = nil
        q.toNanos = nil
        return q
    }

    // MARK: - Round trip

    func testAnEventSurvivesTheRoundTripIntact() throws {
        let original = LogEvent(
            recvNanos: base + 5,
            sentNanos: nil,
            host: "storm-09", tag: "stormpump", severity: .error, facility: 16,
            flags: [.malformed, .clockUnset], repeated: 17,
            source: "203.0.113.9", message: "ERROR quorum lost",
            raw: Data([0x01, 0x02, 0xFF])
        )
        try store.insert([original])

        let events = try reader.fetch(query()).events
        XCTAssertEqual(events.count, 1)
        let stored = events[0]
        XCTAssertEqual(stored.recvNanos, original.recvNanos)
        XCTAssertNil(stored.sentNanos)
        XCTAssertEqual(stored.host, original.host)
        XCTAssertEqual(stored.tag, original.tag)
        XCTAssertEqual(stored.severity, .error)
        XCTAssertEqual(stored.flags, original.flags)
        XCTAssertEqual(stored.repeated, 17)
        XCTAssertEqual(stored.source, original.source)
        XCTAssertEqual(stored.message, original.message)
        XCTAssertEqual(stored.raw, original.raw)
    }

    func testAnEventWithNoSenderTimeOrdersByReceiveTime() throws {
        try store.insert([
            LogEvent(recvNanos: base + 200, sentNanos: nil, host: "a", tag: "t",
                     severity: .info, flags: [.clockUnset], source: "s", message: "no clock"),
            LogEvent(recvNanos: base + 100, sentNanos: base + 100, host: "a", tag: "t",
                     severity: .info, source: "s", message: "has clock"),
        ])
        let events = try reader.fetch(query()).events
        XCTAssertEqual(events.map(\.message), ["has clock", "no clock"],
                       "the clockless event sorts by when we heard it, not to the front or the back")
    }

    // MARK: - The page

    func testTheDefaultPageIsTheTailOfTheStreamInReadingOrder() throws {
        try insert(500)
        var q = query()
        q.limit = 100

        let outcome = try reader.fetch(q)
        XCTAssertEqual(outcome.events.count, 100)
        XCTAssertEqual(outcome.events.first?.message, "line 400", "the page is the newest 100…")
        XCTAssertEqual(outcome.events.last?.message, "line 499", "…presented oldest-first, so it reads like a log")
        XCTAssertTrue(outcome.truncated)
    }

    // MARK: - Filters

    func testFiltersCompose() throws {
        try insert(10, host: "storm-01", tag: "stormblock", severity: .info)
        try insert(10, host: "storm-01", tag: "stormblock", severity: .error, startingAt: 1_000_000_000)
        try insert(10, host: "storm-02", tag: "stormblock", severity: .error, startingAt: 2_000_000_000)
        try insert(10, host: "storm-01", tag: "registry", severity: .error, startingAt: 3_000_000_000)

        XCTAssertEqual(try reader.fetch(query { $0.hosts = ["storm-01"] }).events.count, 30)
        XCTAssertEqual(try reader.fetch(query { $0.severities = [.error] }).events.count, 30)
        XCTAssertEqual(try reader.fetch(query {
            $0.hosts = ["storm-01"]
            $0.severities = [.error]
        }).events.count, 20)
        XCTAssertEqual(try reader.fetch(query {
            $0.hosts = ["storm-01"]
            $0.severities = [.error]
            $0.tags = ["registry"]
        }).events.count, 10)
    }

    func testFlagFilterFindsExactlyTheFlaggedEvents() throws {
        try insert(5, flags: [])
        try insert(3, flags: [.malformed], startingAt: 1_000_000_000)
        try insert(2, flags: [.malformed, .clockUnset], startingAt: 2_000_000_000)

        XCTAssertEqual(try reader.fetch(query { $0.requiredFlags = .malformed }).events.count, 5)
        XCTAssertEqual(try reader.fetch(query { $0.requiredFlags = [.malformed, .clockUnset] }).events.count, 2)
    }

    func testTimeRangeIsMeasuredInTheOrderingsOwnColumn() throws {
        try insert(100, spacingNanos: 1_000_000_000)   // one a second

        var filter = FilterState()
        filter.range = .window(from: base + 10_000_000_000, to: base + 19_000_000_000)
        let q = filter.query(ordering: .receiveTime, limit: 1000)
        XCTAssertEqual(try reader.fetch(q).events.count, 10)
    }

    // MARK: - Search

    func testWordSearchIsIndexedAndMatchesPrefixes() throws {
        try store.insert([
            event("volume vol-421 attached, 4 ublk queues"),
            event("peer storm-02 joined the ring"),
            event("checkpoint written in 12ms"),
        ])

        XCTAssertEqual(try search("volume").count, 1)
        XCTAssertEqual(try search("vol").count, 1, "a prefix finds the word")
        XCTAssertEqual(try search("checkpoint written").count, 1, "terms are ANDed")
        XCTAssertEqual(try search("volume checkpoint").count, 0)
        XCTAssertEqual(try search("nothing").count, 0)
    }

    func testWordSearchDoesNotChokeOnPunctuationPastedFromALogLine() throws {
        try store.insert([event("failed to open \"vol-421\": no such device")])
        XCTAssertNoThrow(try search("\"vol-421\":"))
        XCTAssertNoThrow(try search("*"))
        XCTAssertNoThrow(try search("a AND OR NOT b"))
    }

    /// The distinction the spec insists the viewer be honest about: this one is
    /// a scan, and it finds things a token index cannot.
    func testSubstringSearchFindsWhatWordSearchCannot() throws {
        try store.insert([event("reconciled 4212 volumes")])

        // "421" is a prefix of the token "4212", so the index does find it.
        XCTAssertEqual(try search("421", mode: .tokens).count, 1)
        // "212" is inside that token but not a prefix of it, which is exactly
        // the case the index cannot answer and the scan can.
        XCTAssertEqual(try search("212", mode: .tokens).count, 0, "not a token prefix")
        XCTAssertEqual(try search("212", mode: .substring).count, 1)
    }

    func testSubstringSearchTreatsWildcardsAsLiterals() throws {
        try store.insert([event("100% of pages"), event("100 of pages")])
        XCTAssertEqual(try search("100%", mode: .substring).count, 1)
        XCTAssertEqual(try search("_", mode: .substring).count, 0)
    }

    func testAQueryKnowsWhetherItWillScan() {
        XCTAssertFalse(query { $0.searchText = "x"; $0.searchMode = .tokens }.requiresScan)
        XCTAssertTrue(query { $0.searchText = "x"; $0.searchMode = .substring }.requiresScan)
        XCTAssertFalse(query().requiresScan)
    }

    private func event(_ message: String, host: String = "storm-01") -> LogEvent {
        LogEvent(recvNanos: base + Int64(abs(message.hashValue % 1_000_000)), sentNanos: nil,
                 host: host, tag: "stormblock", severity: .info, source: "203.0.113.1", message: message)
    }

    private func search(_ text: String, mode: SearchMode = .tokens) throws -> [LogEvent] {
        try reader.fetch(query { $0.searchText = text; $0.searchMode = mode }).events
    }

    // MARK: - The fleet

    func testFleetReportsTheWorstSeverityAndWhoIsTalking() throws {
        try insert(10, host: "storm-01", severity: .info)
        try insert(3, host: "storm-01", severity: .error, startingAt: 1_000_000)
        try insert(5, host: "storm-02", severity: .warning, startingAt: 2_000_000)

        let fleet = try reader.fleet(sinceNanos: base - 1)
        XCTAssertEqual(fleet.count, 2)
        let first = try XCTUnwrap(fleet.first { $0.host == "storm-01" })
        XCTAssertEqual(first.events, 13)
        XCTAssertEqual(first.worst, .error)
        let second = try XCTUnwrap(fleet.first { $0.host == "storm-02" })
        XCTAssertEqual(second.worst, .warning)
    }

    func testTheDirectoryRemembersHostsAndTagsThatHaveGoneQuiet() throws {
        try insert(1, host: "storm-01", tag: "stormblock")
        try insert(1, host: "storm-02", tag: "registry", startingAt: 1)

        XCTAssertEqual(try reader.knownHosts(), ["storm-01", "storm-02"])
        XCTAssertEqual(try reader.knownTags(), ["registry", "stormblock"])
    }

    // MARK: - Retention

    func testAgeRetentionDropsTheOldestEventsAndKeepsTheRest() throws {
        let day: Int64 = 86_400 * 1_000_000_000
        let now = base + 40 * day
        try store.insert((0..<40).map { i in
            LogEvent(recvNanos: base + Int64(i) * day, sentNanos: nil, host: "storm-01",
                     tag: "t", severity: .info, source: "s", message: "day \(i)")
        })

        let policy = RetentionPolicy(maxBytes: .max, maxAgeNanos: 10 * day)
        let result = try store.enforce(policy, now: now)

        XCTAssertGreaterThan(result.deleted, 0)
        let remaining = try reader.fetch(query()).events
        XCTAssertTrue(remaining.allSatisfy { $0.recvNanos >= now - 10 * day })
        XCTAssertEqual(remaining.last?.message, "day 39", "the newest event is never the one deleted")
    }

    func testRetentionAlsoTakesTheDeletedEventsOutOfTheSearchIndex() throws {
        let day: Int64 = 86_400 * 1_000_000_000
        try store.insert([
            LogEvent(recvNanos: base, sentNanos: nil, host: "h", tag: "t", severity: .info,
                     source: "s", message: "distinctiveoldword"),
            LogEvent(recvNanos: base + 30 * day, sentNanos: nil, host: "h", tag: "t", severity: .info,
                     source: "s", message: "distinctivenewword"),
        ])
        XCTAssertEqual(try search("distinctiveoldword").count, 1)

        _ = try store.enforce(RetentionPolicy(maxBytes: .max, maxAgeNanos: day),
                              now: base + 30 * day)

        XCTAssertEqual(try search("distinctiveoldword").count, 0,
                       "an external-content FTS index left behind would return rows that no longer exist")
        XCTAssertEqual(try search("distinctivenewword").count, 1)
    }

    func testRetentionLeavesAnUnderBudgetStoreAlone() throws {
        try insert(100)
        let result = try store.enforce(.default, now: base + 1_000_000_000)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(try reader.fetch(query()).events.count, 100)
    }

    func testSizeRetentionConvergesUnderTheBudget() throws {
        // Big messages, so a small budget is reachable in a test.
        let filler = String(repeating: "x", count: 4096)
        for batch in 0..<10 {
            try store.insert((0..<200).map { i in
                LogEvent(recvNanos: base + Int64(batch * 200 + i) * 1_000_000, sentNanos: nil,
                         host: "storm-01", tag: "t", severity: .info, source: "s",
                         message: "\(batch)-\(i) \(filler)")
            })
        }
        let before = try store.stats()
        XCTAssertGreaterThan(before.bytes, 2 * 1024 * 1024)

        let budget: Int64 = 1024 * 1024
        _ = try store.enforce(RetentionPolicy(maxBytes: budget, maxAgeNanos: .max), now: base)

        let after = try store.stats()
        XCTAssertLessThan(after.bytes, before.bytes, "incremental vacuum must actually return the space")
        XCTAssertGreaterThan(after.events, 0, "trimming to a budget is not the same as deleting everything")
    }

    func testStatsCountsEventsAndBytes() throws {
        XCTAssertEqual(try store.stats().events, 0)
        try insert(250)
        let stats = try store.stats()
        XCTAssertEqual(stats.events, 250)
        XCTAssertEqual(stats.hosts, 1)
        XCTAssertGreaterThan(stats.bytes, 0)
        XCTAssertEqual(stats.oldestNanos, base)
    }

    func testCountMatchingSaysWhenItStoppedCounting() throws {
        try insert(500)
        let exact = try reader.countMatching(query(), ceiling: 10_000)
        XCTAssertEqual(exact.count, 500)
        XCTAssertTrue(exact.exact)

        let capped = try reader.countMatching(query(), ceiling: 100)
        XCTAssertEqual(capped.count, 100)
        XCTAssertFalse(capped.exact, "a truncated count must not be presented as an exact one")
    }

    func testDeleteAllEmptiesEverything() throws {
        try insert(50)
        try store.deleteAll()
        XCTAssertEqual(try store.stats().events, 0)
        XCTAssertEqual(try reader.knownHosts(), [])
        XCTAssertEqual(try reader.fetch(query()).events.count, 0)
    }

    // MARK: - Reopening

    func testTheStoreReopensWithItsContentsIntact() throws {
        try insert(20)
        let path = store.path
        reader = nil
        store = nil

        store = try EventStore(path: path)
        reader = try store.makeReader()
        XCTAssertEqual(try reader.fetch(query()).events.count, 20)
        XCTAssertEqual(try search("line").count, 20, "the search index survives a reopen too")
    }
}
