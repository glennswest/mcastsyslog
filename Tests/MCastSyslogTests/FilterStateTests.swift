import XCTest
@testable import MCastSyslog

/// The live tail appends without asking the database anything, so the Swift
/// predicate and the SQL have to agree about what matches. Where they drift,
/// the view drifts from the corpus behind it — and you would only find out by
/// changing a filter and watching rows appear that were there all along.
final class FilterStateTests: XCTestCase {

    private let now: Int64 = 1_787_000_000_000_000_000

    private func event(
        host: String = "storm-01",
        tag: String = "stormblock",
        severity: Severity = .info,
        flags: EventFlags = [],
        message: String = "volume vol-421 attached",
        at offset: Int64 = 0
    ) -> LogEvent {
        LogEvent(recvNanos: now + offset, sentNanos: now + offset, host: host, tag: tag,
                 severity: severity, flags: flags, source: "203.0.113.1", message: message)
    }

    private func matches(_ event: LogEvent, _ build: (inout FilterState) -> Void) -> Bool {
        var filter = FilterState()
        build(&filter)
        return filter.matches(event, ordering: .senderTime, now: now)
    }

    func testAnEmptyFilterMatchesEverything() {
        XCTAssertTrue(matches(event()) { _ in })
    }

    func testEachFilterNarrows() {
        XCTAssertTrue(matches(event()) { $0.hosts = ["storm-01"] })
        XCTAssertFalse(matches(event()) { $0.hosts = ["storm-02"] })
        XCTAssertTrue(matches(event()) { $0.tags = ["stormblock"] })
        XCTAssertFalse(matches(event()) { $0.tags = ["registry"] })
        XCTAssertTrue(matches(event(severity: .error)) { $0.severities = [.error] })
        XCTAssertFalse(matches(event(severity: .info)) { $0.severities = [.error] })
    }

    func testFlagsMustAllBePresent() {
        XCTAssertTrue(matches(event(flags: [.malformed, .clockUnset])) { $0.requiredFlags = .malformed })
        XCTAssertFalse(matches(event(flags: [.clockUnset])) { $0.requiredFlags = .malformed })
        XCTAssertFalse(matches(event(flags: [.malformed])) { $0.requiredFlags = [.malformed, .clockUnset] })
    }

    func testWordSearchMatchesWordPrefixesTheWayFTSDoes() {
        XCTAssertTrue(matches(event()) { $0.searchText = "volume"; $0.searchMode = .tokens })
        XCTAssertTrue(matches(event()) { $0.searchText = "vol"; $0.searchMode = .tokens })
        XCTAssertTrue(matches(event()) { $0.searchText = "volume attached"; $0.searchMode = .tokens })
        XCTAssertTrue(matches(event()) { $0.searchText = "421"; $0.searchMode = .tokens },
                      "vol-421 tokenises to vol and 421, so this is a whole token")
        XCTAssertFalse(matches(event()) { $0.searchText = "21"; $0.searchMode = .tokens },
                       "inside a token but not a prefix of it — the same answer the FTS index gives")
        XCTAssertFalse(matches(event()) { $0.searchText = "volume missing"; $0.searchMode = .tokens })
    }

    func testSubstringSearchMatchesAnywhereAndIgnoresCase() {
        XCTAssertTrue(matches(event()) { $0.searchText = "421"; $0.searchMode = .substring })
        XCTAssertTrue(matches(event()) { $0.searchText = "VOLUME"; $0.searchMode = .substring })
        XCTAssertFalse(matches(event()) { $0.searchText = "detached"; $0.searchMode = .substring })
    }

    /// A pinned window is a decision to stop moving. New events belong to the
    /// unseen count, not to the view.
    func testNothingArrivingNowBelongsInAPinnedWindow() {
        XCTAssertFalse(matches(event()) { $0.range = .window(from: now - 1000, to: now + 1000) })
        XCTAssertTrue(matches(event()) { $0.range = .live })
        XCTAssertTrue(matches(event()) { $0.range = .lastMinutes(5) })
        XCTAssertFalse(matches(event(at: -10 * 60 * 1_000_000_000)) { $0.range = .lastMinutes(5) })
    }

    func testTheQueryUsesTheColumnThatMatchesTheOrdering() {
        var filter = FilterState()
        filter.range = .lastMinutes(5)
        XCTAssertEqual(filter.query(ordering: .senderTime, limit: 10).timeColumn, "event_ns")
        XCTAssertEqual(filter.query(ordering: .receiveTime, limit: 10).timeColumn, "recv_ns")
    }

    func testIsActiveTracksWhetherAnythingIsFilteringAtAll() {
        var filter = FilterState()
        XCTAssertFalse(filter.isActive)
        filter.searchText = "  "
        XCTAssertTrue(filter.isActive)
        XCTAssertNil(filter.search, "whitespace is not a search")
    }
}
