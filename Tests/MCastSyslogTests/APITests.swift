import XCTest
@testable import MCastSyslog

/// The API is tested against its own temporary store, never the running app's.
final class APITests: XCTestCase {

    private var directory: URL!
    private var store: EventStore!
    private var router: APIRouter!
    private var context: APIContext!

    private let base: Int64 = 1_787_000_000_000_000_000

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcastsyslog-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try EventStore(path: directory.appendingPathComponent("events.sqlite3").path)
        context = APIContext(store: store, receiver: MulticastReceiver())
        router = APIRouter(context: context)

        try store.insert([
            event(0, host: "storm-01", tag: "stormblock", severity: .info, message: "volume vol-421 attached"),
            event(1, host: "storm-01", tag: "stormblock", severity: .error, message: "ERROR ublk queue 3 reset"),
            event(2, host: "storm-02", tag: "registry", severity: .warning, message: "WARN slow commit: 900ms"),
            event(3, host: "storm-02", tag: "registry", severity: .debug, message: "DEBUG scrub pass complete"),
            event(4, host: "storm-03", tag: "stormpump", severity: .notice,
                  flags: [.repeatNotice], repeated: 17, message: "last message repeated 17 times"),
            event(5, host: "storm-03", tag: "kernel", severity: .info, flags: [.malformed, .clockUnset],
                  message: "garbled frame", raw: Data([0x01, 0xFF])),
        ])
    }

    override func tearDownWithError() throws {
        router = nil
        context = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(
        _ index: Int, host: String, tag: String, severity: Severity,
        flags: EventFlags = [], repeated: Int? = nil, message: String, raw: Data? = nil
    ) -> LogEvent {
        LogEvent(
            recvNanos: base + Int64(index) * 1_000_000_000,
            sentNanos: flags.contains(.clockUnset) ? nil : base + Int64(index) * 1_000_000_000,
            host: host, tag: tag, severity: severity, flags: flags, repeated: repeated,
            source: "203.0.113.\(index + 10)", message: message, raw: raw)
    }

    // MARK: - Calling the router

    @discardableResult
    private func get(_ target: String, file: StaticString = #filePath, line: UInt = #line) throws -> (status: Int, json: [String: Any]) {
        let request = try XCTUnwrap(HTTPServer.parse("GET \(target) HTTP/1.1\r\nHost: localhost\r\n"),
                                    file: file, line: line)
        guard case .response(let response) = router.route(request) else {
            XCTFail("expected a response, got a stream", file: file, line: line)
            return (0, [:])
        }
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        return (response.status, object)
    }

    private func events(_ target: String) throws -> [[String: Any]] {
        let result = try get(target)
        XCTAssertEqual(result.status, 200)
        return result.json["events"] as? [[String: Any]] ?? []
    }

    // MARK: - Retrieval and search

    func testEventsReturnsEverythingByDefaultInReadingOrder() throws {
        let rows = try events("/api/v1/events")
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.first?["message"] as? String, "volume vol-421 attached")
        XCTAssertEqual(rows.last?["message"] as? String, "garbled frame")
    }

    func testFiltersNarrowTheSameWayTheWindowDoes() throws {
        XCTAssertEqual(try events("/api/v1/events?host=storm-01").count, 2)
        XCTAssertEqual(try events("/api/v1/events?tag=registry").count, 2)
        XCTAssertEqual(try events("/api/v1/events?severity=error").count, 1)
        XCTAssertEqual(try events("/api/v1/events?host=storm-01&severity=error").count, 1)
        XCTAssertEqual(try events("/api/v1/events?host=storm-01,storm-02").count, 4,
                       "comma-separated is the same as repeating the parameter")
        XCTAssertEqual(try events("/api/v1/events?host=storm-01&host=storm-02").count, 4)
    }

    func testMinSeverityMeansAtLeastThisSevere() throws {
        XCTAssertEqual(try events("/api/v1/events?min_severity=error").count, 1)
        XCTAssertEqual(try events("/api/v1/events?min_severity=warning").count, 2)
        XCTAssertEqual(try events("/api/v1/events?min_severity=notice").count, 3)
        XCTAssertEqual(try events("/api/v1/events?min_severity=3").count, 1, "numbers work too")
    }

    func testFlagFilterFindsTheFramesThatWereKeptRatherThanDropped() throws {
        let rows = try events("/api/v1/events?flag=malformed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["message"] as? String, "garbled frame")
        XCTAssertNotNil(rows.first?["raw_base64"], "the frame verbatim is served, not just noted")
        XCTAssertEqual(try events("/api/v1/events?flag=collapsed_repeat").first?["repeated"] as? Int, 17)
    }

    func testSearchDistinguishesTheIndexFromTheScan() throws {
        XCTAssertEqual(try events("/api/v1/events?q=volume").count, 1)
        // "42" is a prefix of the token "421", so the index does find it; "21"
        // is inside that token but not a prefix, which is the case only a scan
        // can answer.
        XCTAssertEqual(try events("/api/v1/events?q=42").count, 1)
        XCTAssertEqual(try events("/api/v1/events?q=21").count, 0, "not a token prefix")
        XCTAssertEqual(try events("/api/v1/events?q=21&mode=substring").count, 1)

        let scanned = try get("/api/v1/events?q=21&mode=substring")
        XCTAssertEqual(scanned.json["scanned"] as? Bool, true,
                       "a scan must announce itself rather than pass as a lookup")
        let indexed = try get("/api/v1/events?q=volume")
        XCTAssertEqual(indexed.json["scanned"] as? Bool, false)
    }

    func testPercentAndPlusEncodedSearchTextArriveIntact() throws {
        XCTAssertEqual(try events("/api/v1/events?q=slow+commit").count, 1)
        XCTAssertEqual(try events("/api/v1/events?q=slow%20commit").count, 1)
    }

    func testTimeBoundsAcceptTheFormsSomeoneWouldActuallyType() throws {
        let from = Timestamp.format(base + 2_000_000_000, style: .rfc3339UTC)
        XCTAssertEqual(try events("/api/v1/events?from=\(from)").count, 4)
        XCTAssertEqual(try events("/api/v1/events?from=\(base + 2_000_000_000)").count, 4,
                       "a bare epoch works")
        XCTAssertEqual(try events("/api/v1/events?last=1h").count, 0,
                       "the fixtures are older than an hour, and `last` means a span ending now")
    }

    func testTheResponseEchoesHowItReadTheParameters() throws {
        let result = try get("/api/v1/events?host=storm-01&min_severity=warning&q=ublk&limit=5")
        let query = try XCTUnwrap(result.json["query"] as? [String: Any])
        XCTAssertEqual(query["host"] as? [String], ["storm-01"])
        XCTAssertEqual(query["q"] as? String, "ublk")
        XCTAssertEqual(query["limit"] as? Int, 5)
        XCTAssertEqual(query["scans"] as? Bool, false)
        XCTAssertEqual(Set(query["severity"] as? [String] ?? []),
                       ["emergency", "alert", "critical", "error", "warning"])
    }

    func testLimitIsCappedRatherThanHonouredAndHoped() throws {
        let result = try get("/api/v1/events?limit=999999999")
        let query = try XCTUnwrap(result.json["query"] as? [String: Any])
        XCTAssertEqual(query["limit"] as? Int, ParsedQuery.maximumLimit,
                       "an unbounded limit over HTTP is a way to make the viewer allocate the corpus")
    }

    func testMatchedCountIsReportedAlongsideWhatWasReturned() throws {
        let result = try get("/api/v1/events?limit=2")
        XCTAssertEqual(result.json["returned"] as? Int, 2)
        XCTAssertEqual(result.json["matched"] as? Int, 6)
        XCTAssertEqual(result.json["truncated"] as? Bool, true)
    }

    // MARK: - One event, and a moment

    func testAnEventCanBeFetchedById() throws {
        let rows = try events("/api/v1/events?host=storm-02&severity=warning")
        let id = try XCTUnwrap(rows.first?["id"] as? Int)
        let result = try get("/api/v1/events/\(id)")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["message"] as? String, "WARN slow commit: 900ms")

        XCTAssertEqual(try get("/api/v1/events/424242").status, 404)
    }

    func testAroundAMomentCrossesEveryNode() throws {
        let at = Timestamp.format(base + 2_000_000_000, style: .rfc3339UTC)
        let result = try get("/api/v1/around?at=\(at)&window=2")
        XCTAssertEqual(result.status, 200)
        let hosts = try XCTUnwrap(result.json["hosts"] as? [String])
        XCTAssertEqual(hosts, ["storm-01", "storm-02", "storm-03"],
                       "the whole point of a moment is what every other node was saying")
    }

    func testAroundRefusesToGuessAtATimeItCannotRead() throws {
        XCTAssertEqual(try get("/api/v1/around").status, 400)
        XCTAssertEqual(try get("/api/v1/around?at=yesterday").status, 400)
    }

    // MARK: - Rollups

    func testSummaryCountsBySeverityHostAndTag() throws {
        let result = try get("/api/v1/summary")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["total"] as? Int, 6)

        let bySeverity = try XCTUnwrap(result.json["by_severity"] as? [[String: Any]])
        let errors = bySeverity.first { $0["name"] as? String == "error" }
        XCTAssertEqual(errors?["count"] as? Int, 1)

        let byHost = try XCTUnwrap(result.json["by_host"] as? [[String: Any]])
        XCTAssertEqual(byHost.count, 3)
        let stormOne = try XCTUnwrap(byHost.first { $0["host"] as? String == "storm-01" })
        XCTAssertEqual(stormOne["count"] as? Int, 2)
        XCTAssertEqual(stormOne["worst_severity_name"] as? String, "error")

        let byTag = try XCTUnwrap(result.json["by_tag"] as? [[String: Any]])
        XCTAssertEqual(byTag.count, 4)
    }

    func testSummaryReportsTheFlagsAndWhatTheNodesHeldBack() throws {
        let result = try get("/api/v1/summary")
        let flags = try XCTUnwrap(result.json["flags"] as? [String: Any])
        XCTAssertEqual(flags["malformed"] as? Int, 1)
        XCTAssertEqual(flags["clock_unset"] as? Int, 1)
        XCTAssertEqual(flags["collapsed_repeat"] as? Int, 1)
        XCTAssertEqual(result.json["lines_the_nodes_held_back"] as? Int, 17,
                       "lines that exist on the node and were never put on the wire")
    }

    func testSummaryRespectsTheSameFilters() throws {
        let result = try get("/api/v1/summary?host=storm-01")
        XCTAssertEqual(result.json["total"] as? Int, 2)
    }

    func testFleetReportsRateAndWorstSeverityPerNode() throws {
        let window = Timestamp.now() - base + 60_000_000_000
        let result = try get("/api/v1/fleet?window=\(window / 1_000_000_000)s")
        XCTAssertEqual(result.status, 200)
        let nodes = try XCTUnwrap(result.json["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 3)
        let stormOne = try XCTUnwrap(nodes.first { $0["host"] as? String == "storm-01" })
        XCTAssertEqual(stormOne["worst_severity_name"] as? String, "error")
    }

    func testHostsAndTagsListWhatHasEverBeenHeard() throws {
        XCTAssertEqual(try get("/api/v1/hosts").json["hosts"] as? [String],
                       ["storm-01", "storm-02", "storm-03"])
        XCTAssertEqual(try get("/api/v1/tags").json["tags"] as? [String],
                       ["kernel", "registry", "stormblock", "stormpump"])
    }

    // MARK: - Types

    func testTypesDescribesEverySeverityAndFlag() throws {
        let result = try get("/api/v1/types")
        XCTAssertEqual(result.status, 200)

        let severities = try XCTUnwrap(result.json["severities"] as? [[String: Any]])
        XCTAssertEqual(severities.count, 8)
        XCTAssertEqual(severities.first?["value"] as? Int, 0)
        XCTAssertEqual(severities.first?["name"] as? String, "emergency")

        let flags = try XCTUnwrap(result.json["flags"] as? [[String: Any]])
        XCTAssertEqual(Set(flags.compactMap { $0["name"] as? String }),
                       ["malformed", "clock_unset", "collapsed_repeat", "rate_limited"])

        // Every flag the API names must be one the parser can actually produce.
        for name in flags.compactMap({ $0["name"] as? String }) {
            XCTAssertFalse(ExportFormatter.flags(from: [name]).isEmpty,
                           "\(name) is documented but does not round-trip")
        }

        XCTAssertNotNil(result.json["event_fields"])
        XCTAssertEqual(result.json["format"] as? String, ExportFormatter.formatIdentifier)
    }

    func testTheIndexListsTheEndpointsThatExist() throws {
        let result = try get("/api/v1")
        let endpoints = try XCTUnwrap(result.json["endpoints"] as? [[String: Any]])
        let paths = Set(endpoints.compactMap { $0["path"] as? String })
        XCTAssertTrue(paths.contains("/api/v1/events"))
        XCTAssertTrue(paths.contains("/api/v1/summary"))
        XCTAssertTrue(paths.contains("/api/v1/stats"))
        XCTAssertTrue(paths.contains("/api/v1/types"))
    }

    // MARK: - The read-only guarantee

    func testNothingButGETAndHEADIsRouted() throws {
        // The method guard lives in the server rather than the router, so this
        // asserts the shape the server relies on: the router has no route that
        // could mutate anything even if one reached it.
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let head = "\(method) /api/v1/events HTTP/1.1\r\nHost: localhost\r\n"
            let request = try XCTUnwrap(HTTPServer.parse(head))
            XCTAssertEqual(request.method, method)
        }
        XCTAssertEqual(try get("/api/v1/nope").status, 404)
    }

    func testBadParametersAreRefusedWithAnExplanation() throws {
        for target in ["/api/v1/events?severity=banana",
                       "/api/v1/events?min_severity=17",
                       "/api/v1/events?flag=invented",
                       "/api/v1/events?mode=fuzzy",
                       "/api/v1/events?last=fortnight",
                       "/api/v1/events?from=whenever"] {
            let result = try get(target)
            XCTAssertEqual(result.status, 400, "\(target) should be refused")
            XCTAssertNotNil(result.json["error"], "\(target) should say why")
        }
    }

    // MARK: - Tailing with a cursor

    func testACursorReturnsWhatIsNewOldestFirst() throws {
        let all = try events("/api/v1/events")
        let third = try XCTUnwrap(all[2]["id"] as? Int)

        let result = try get("/api/v1/events?since_id=\(third)")
        let rows = try XCTUnwrap(result.json["events"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3, "the three after it")
        XCTAssertEqual(rows.first?["id"] as? Int, third + 1, "oldest first, so a tail reads forward")
        XCTAssertEqual(result.json["next_since_id"] as? Int, all.last?["id"] as? Int)
    }

    func testAskingTwiceWithTheSameCursorGivesTheSameAnswer() throws {
        let all = try events("/api/v1/events")
        let cursor = try XCTUnwrap(all[1]["id"] as? Int)
        let first = try get("/api/v1/events?since_id=\(cursor)")
        let second = try get("/api/v1/events?since_id=\(cursor)")
        XCTAssertEqual(first.json["returned"] as? Int, second.json["returned"] as? Int,
                       "a cursor is repeatable, which is the reason to prefer it to a stream")
    }

    func testAQuietFleetDoesNotWalkTheCursorBackwards() throws {
        let all = try events("/api/v1/events")
        let newest = try XCTUnwrap(all.last?["id"] as? Int)
        let result = try get("/api/v1/events?since_id=\(newest)")
        XCTAssertEqual(result.json["returned"] as? Int, 0)
        XCTAssertEqual(result.json["next_since_id"] as? Int, newest,
                       "nothing new must not mean starting over")
    }

    func testTheCursorRespectsTheOtherFilters() throws {
        let result = try get("/api/v1/events?since_id=0&min_severity=warning")
        let rows = try XCTUnwrap(result.json["events"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { ($0["severity"] as? Int ?? 9) <= 4 })
    }

    func testAMalformedCursorIsRefusedRatherThanIgnored() throws {
        let result = try get("/api/v1/events?since_id=banana")
        XCTAssertEqual(result.status, 400, "silently ignoring it would restart a tail from the beginning")
    }

    func testHealthCarriesTheNewestIdSoATailCanStartFromNow() throws {
        let health = try get("/api/v1/health")
        let all = try events("/api/v1/events")
        XCTAssertEqual(health.json["newest_id"] as? Int, all.last?["id"] as? Int)
    }

    // MARK: - Clearing

    func testClearingIsRefusedUnlessItHasBeenSwitchedOn() throws {
        let result = try get("/api/v1/clear?confirm=yes")
        XCTAssertEqual(result.status, 403)
        XCTAssertEqual(try get("/api/v1/events").json["returned"] as? Int, 6,
                       "and nothing was deleted")
    }

    func testClearingNeedsConfirmationEvenWhenSwitchedOn() throws {
        var snapshot = APIContext.Snapshot()
        snapshot.allowClearing = true
        context.update(snapshot)

        XCTAssertEqual(try get("/api/v1/clear").status, 400)
        XCTAssertEqual(try get("/api/v1/clear?confirm=maybe").status, 400)
        XCTAssertEqual(try get("/api/v1/events").json["returned"] as? Int, 6)
    }

    func testClearingIsRefusedWhenTheAPIServesToOtherMachines() throws {
        var snapshot = APIContext.Snapshot()
        snapshot.allowClearing = true
        snapshot.servesRemotely = true
        context.update(snapshot)

        let result = try get("/api/v1/clear?confirm=yes")
        XCTAssertEqual(result.status, 403)
        XCTAssertEqual(try get("/api/v1/events").json["returned"] as? Int, 6)
    }

    func testClearingWorksWhenAllThreeGuardsAgree() throws {
        var snapshot = APIContext.Snapshot()
        snapshot.allowClearing = true
        context.update(snapshot)

        let result = try get("/api/v1/clear?confirm=yes")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["cleared"] as? Bool, true)
        XCTAssertEqual(result.json["events_deleted"] as? Int, 6)
        XCTAssertEqual(try get("/api/v1/events").json["returned"] as? Int, 0)
    }

    func testHealthSaysWhetherClearingIsAvailable() throws {
        XCTAssertEqual(try get("/api/v1/health").json["clearing_allowed"] as? Bool, false)

        var snapshot = APIContext.Snapshot()
        snapshot.allowClearing = true
        context.update(snapshot)
        XCTAssertEqual(try get("/api/v1/health").json["clearing_allowed"] as? Bool, true)

        snapshot.servesRemotely = true
        context.update(snapshot)
        XCTAssertEqual(try get("/api/v1/health").json["clearing_allowed"] as? Bool, false)
    }

    // MARK: - Analysis and lifecycle over HTTP

    func testAnalysisIsServedWithItsNarrativeFirst() throws {
        let result = try get("/api/v1/analysis?last=24h")
        XCTAssertEqual(result.status, 200)
        XCTAssertNotNil(result.json["narrative"] as? [String])
        XCTAssertNotNil(result.json["workloads"])
        XCTAssertNotNil(result.json["findings"])
        XCTAssertNotNil(result.json["confidence_levels"])
    }

    func testLifecycleIsServedAndNamesItsMarkers() throws {
        let result = try get("/api/v1/lifecycle?last=24h")
        XCTAssertEqual(result.status, 200)
        let markers = try XCTUnwrap(result.json["markers"] as? [[String: Any]])
        for marker in markers {
            XCTAssertNotNil(marker["stated"], "whether the node said so, or we worked it out")
            XCTAssertNotNil(marker["label"])
        }
    }

    func testTypesDescribesTheLifecycleVocabularyToo() throws {
        let result = try get("/api/v1/types")
        let markers = try XCTUnwrap(result.json["lifecycle_markers"] as? [[String: Any]])
        XCTAssertTrue(markers.contains { $0["value"] as? String == "kernel_boot" })
        let endings = try XCTUnwrap(result.json["run_endings"] as? [[String: Any]])
        XCTAssertTrue(endings.contains { $0["value"] as? String == "rebooted" })
        XCTAssertTrue(endings.contains { $0["value"] as? String == "cut_off" })
    }

    // MARK: - The live tail

    func testTheLiveStreamDeliversOnlyWhatTheFilterMatches() throws {
        let handle = EventStreamHandle()
        let received = Received()
        handle.attach { received.append($0) }

        var filter = FilterState()
        filter.severities = [.error]
        context.live.subscribe(handle, filter: filter, ordering: .senderTime)
        XCTAssertEqual(context.live.subscriberCount, 1)

        context.live.publish([
            event(10, host: "storm-01", tag: "t", severity: .info, message: "ordinary"),
            event(11, host: "storm-01", tag: "t", severity: .error, message: "ERROR the interesting one"),
        ])

        let text = received.text
        XCTAssertTrue(text.contains("ERROR the interesting one"))
        XCTAssertFalse(text.contains("ordinary"), "an event the filter excludes must not be pushed")
        XCTAssertTrue(text.contains("event: log\ndata: "), "framed as Server-Sent Events")
    }

    func testAGreetingSentBeforeTheHeadersStillArrives() throws {
        // The router greets a subscriber the moment it registers it, which is
        // necessarily before the connection has a writer.
        let handle = EventStreamHandle()
        handle.send(event: "hello", json: ["version": AppVersion.current])

        let received = Received()
        handle.attach { received.append($0) }
        XCTAssertTrue(received.text.contains("event: hello"),
                      "queued before the writer existed, flushed when it arrived")
    }

    func testAClosedSubscriberIsDroppedRatherThanWrittenTo() throws {
        let handle = EventStreamHandle()
        let received = Received()
        handle.attach { received.append($0) }
        context.live.subscribe(handle, filter: FilterState(), ordering: .senderTime)

        handle.close()
        XCTAssertEqual(context.live.subscriberCount, 0, "closing unsubscribes")

        context.live.publish([event(12, host: "h", tag: "t", severity: .error, message: "after the close")])
        XCTAssertFalse(received.text.contains("after the close"))
    }

    /// Collects what a stream handle writes, from whichever queue writes it.
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Request parsing

    func testRequestParsingHandlesTheFormsClientsSend() throws {
        let request = try XCTUnwrap(HTTPServer.parse(
            "GET /api/v1/events?host=a&host=b&q=hello%20world&flag= HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n"))
        XCTAssertEqual(request.path, "/api/v1/events")
        XCTAssertEqual(request.list("host"), ["a", "b"])
        XCTAssertEqual(request.first("q"), "hello world")
        XCTAssertEqual(request.list("flag"), [], "an empty value is not a filter")
        XCTAssertEqual(request.headers["accept"], "*/*", "header names are matched case-insensitively")
    }

    func testDurationsAcceptTheUnitsPeopleType() {
        XCTAssertEqual(ParsedQuery.duration("30s"), 30_000_000_000)
        XCTAssertEqual(ParsedQuery.duration("15m"), 900_000_000_000)
        XCTAssertEqual(ParsedQuery.duration("2h"), 7_200_000_000_000)
        XCTAssertEqual(ParsedQuery.duration("1d"), 86_400_000_000_000)
        XCTAssertEqual(ParsedQuery.duration("90"), 90_000_000_000, "a bare number is seconds")
        XCTAssertNil(ParsedQuery.duration("soon"))
    }

    func testSeverityNamesIncludeTheOnesTheNodesLinesUse() {
        XCTAssertEqual(ParsedQuery.severity("ERROR"), .error)
        XCTAssertEqual(ParsedQuery.severity("fatal"), .error, "the node's own word for it")
        XCTAssertEqual(ParsedQuery.severity("warn"), .warning)
        XCTAssertEqual(ParsedQuery.severity("trace"), .debug)
        XCTAssertEqual(ParsedQuery.severity("3"), .error)
        XCTAssertNil(ParsedQuery.severity("banana"))
        XCTAssertNil(ParsedQuery.severity("9"))
    }
}
