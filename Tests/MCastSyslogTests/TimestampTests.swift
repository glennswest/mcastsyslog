import XCTest
@testable import MCastSyslog

final class TimestampTests: XCTestCase {

    func testParsesRFC3339WithMicroseconds() {
        let ns = Timestamp.parseRFC3339("2026-08-24T21:47:11.123456Z")
        XCTAssertEqual(ns, 1_787_608_031_123_456_000)
    }

    func testKeepsMicrosecondsThatADoubleWouldRoundAway() {
        // The whole reason for parsing by hand: Date's seconds-as-Double cannot
        // represent this exactly at a 2026 epoch, and the node sends it.
        let ns = Timestamp.parseRFC3339("2026-08-24T21:47:11.000001Z")!
        XCTAssertEqual(ns % 1_000_000_000, 1_000)
    }

    func testParsesOffsetsInBothForms() {
        let utc = Timestamp.parseRFC3339("2026-08-24T21:47:11Z")!
        XCTAssertEqual(Timestamp.parseRFC3339("2026-08-24T23:47:11+02:00"), utc)
        XCTAssertEqual(Timestamp.parseRFC3339("2026-08-24T19:47:11-0200"), utc)
    }

    func testRejectsThingsThatAreNotTimestamps() {
        XCTAssertNil(Timestamp.parseRFC3339("-"))
        XCTAssertNil(Timestamp.parseRFC3339("2026-08-24"))
        XCTAssertNil(Timestamp.parseRFC3339("2026-13-24T00:00:00Z"))
        XCTAssertNil(Timestamp.parseRFC3339("2026-08-24T21:47:11Z junk"))
        XCTAssertNil(Timestamp.parseRFC3339(""))
    }

    func testRoundTripsThroughRFC3339Formatting() {
        for text in [
            "2026-08-24T21:47:11.123456Z",
            "2020-01-01T00:00:00.000000Z",
            "1999-12-31T23:59:59.999999Z",
            "2038-01-19T03:14:07.000000Z",
        ] {
            let ns = Timestamp.parseRFC3339(text)!
            XCTAssertEqual(Timestamp.format(ns, style: .rfc3339UTC), text)
        }
    }

    func testCivilCalendarRoundTripsAcrossLeapYearsAndCenturies() {
        for (y, m, d) in [(2000, 2, 29), (1900, 3, 1), (2024, 2, 29), (2100, 3, 1), (1970, 1, 1)] {
            let days = Timestamp.daysFromCivil(year: y, month: m, day: d)
            let back = Timestamp.civilFromDays(days)
            XCTAssertEqual(back.year, y)
            XCTAssertEqual(back.month, m)
            XCTAssertEqual(back.day, d)
        }
    }

    func testEpochZeroIsTheEpoch() {
        XCTAssertEqual(Timestamp.daysFromCivil(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(Timestamp.format(0, style: .rfc3339UTC), "1970-01-01T00:00:00.000000Z")
    }

    func testFormattingHandlesTimesBeforeTheEpoch() {
        let ns = Timestamp.parseRFC3339("1969-07-20T20:17:40.000000Z")!
        XCTAssertLessThan(ns, 0)
        XCTAssertEqual(Timestamp.format(ns, style: .rfc3339UTC), "1969-07-20T20:17:40.000000Z")
    }

    /// What someone pastes into "jump to a moment" — off a log line, out of a
    /// ticket, or from another tool that only speaks epochs.
    func testFlexibleParsingAcceptsWhatAHumanWouldPaste() {
        XCTAssertNotNil(Timestamp.parseFlexible("2026-08-24T21:47:11.123456Z"))
        XCTAssertNotNil(Timestamp.parseFlexible("  2026-08-24 21:47:11  "))
        XCTAssertNotNil(Timestamp.parseFlexible("2026-08-24 21:47"))
        XCTAssertNotNil(Timestamp.parseFlexible("2026-08-24"))
        XCTAssertNil(Timestamp.parseFlexible("yesterday"))
        XCTAssertNil(Timestamp.parseFlexible(""))
    }

    func testFlexibleParsingReadsEpochsAtTheRightScale() {
        let seconds = Timestamp.parseFlexible("1787003231")!
        let millis = Timestamp.parseFlexible("1787003231123")!
        let micros = Timestamp.parseFlexible("1787003231123456")!
        let nanos = Timestamp.parseFlexible("1787003231123456789")!
        XCTAssertEqual(seconds, 1_787_003_231_000_000_000)
        XCTAssertEqual(millis, 1_787_003_231_123_000_000)
        XCTAssertEqual(micros, 1_787_003_231_123_456_000)
        XCTAssertEqual(nanos, 1_787_003_231_123_456_789)
    }

    func testIntervalFormattingPicksAReadablePrecision() {
        XCTAssertEqual(Timestamp.formatInterval(500), "500ns")
        XCTAssertEqual(Timestamp.formatInterval(1_500_000), "1.5ms")
        XCTAssertEqual(Timestamp.formatInterval(90 * 1_000_000_000), "1m 30s")
        XCTAssertEqual(Timestamp.formatInterval(-2 * 1_000_000_000), "-2.00s")
    }
}
