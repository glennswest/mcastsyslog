import XCTest
@testable import MCastSyslog

final class SyslogParserTests: XCTestCase {

    // Addresses throughout the tests come from the RFC 5737 documentation
    // ranges — 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 — which exist so
    // that an example cannot be mistaken for, or collide with, a real network.

    private func parse(_ text: String, from source: String = "203.0.113.10", at recv: Int64 = 1_700_000_000_000_000_000) -> LogEvent {
        SyslogParser.parse(Data(text.utf8), from: source, receivedAt: recv)
    }

    func testParsesTheFrameANodeActuallySends() {
        let event = parse("<131>1 2026-08-24T21:47:11.123456Z storm-01 stormblock - - - ERROR ublk queue 3 reset after io timeout")

        XCTAssertFalse(event.flags.contains(.malformed))
        XCTAssertEqual(event.host, "storm-01")
        XCTAssertEqual(event.tag, "stormblock")
        XCTAssertEqual(event.severity, .error)         // 131 = 16*8 + 3
        XCTAssertEqual(event.facility, 16)             // local0
        XCTAssertEqual(event.message, "ERROR ublk queue 3 reset after io timeout")
        XCTAssertEqual(event.sentNanos, Timestamp.parseRFC3339("2026-08-24T21:47:11.123456Z"))
        XCTAssertEqual(event.recvNanos, 1_700_000_000_000_000_000)
    }

    /// The spec's hardest rule about the parser: a frame that does not parse is
    /// kept, not dropped. A viewer that hides what it cannot parse hides exactly
    /// the interesting failures.
    func testKeepsAnUnparseableFrameVerbatim() {
        let event = parse("this is not syslog at all")

        XCTAssertTrue(event.flags.contains(.malformed))
        XCTAssertEqual(event.severity, .info)
        XCTAssertEqual(event.message, "this is not syslog at all")
        XCTAssertEqual(event.raw, Data("this is not syslog at all".utf8))
        XCTAssertEqual(event.host, "203.0.113.10", "a frame with no hostname is attributed to where it came from")
    }

    func testKeepsAFrameWithAnEmbeddedNulByte() {
        let event = parse("garbled\u{0}frame from storm-03")
        XCTAssertTrue(event.flags.contains(.malformed))
        XCTAssertNotNil(event.raw)
    }

    func testKeepsInvalidUTF8RatherThanDroppingTheLine() {
        var bytes = Array("<134>1 2026-08-24T21:47:11.000000Z storm-01 kernel - - - broken ".utf8)
        bytes.append(0xFF)                              // not valid UTF-8 anywhere
        let event = SyslogParser.parse(Data(bytes), from: "203.0.113.1", receivedAt: 1)
        XCTAssertFalse(event.flags.contains(.malformed))
        XCTAssertTrue(event.message.hasPrefix("broken "))
    }

    func testNilTimestampIsFlaggedRatherThanInvented() {
        let event = parse("<134>1 - storm-09 stormpump - - - lease renewed, ttl 30s")

        XCTAssertNil(event.sentNanos, "a node with no clock must not be given a plausible one")
        XCTAssertTrue(event.flags.contains(.clockUnset))
        XCTAssertFalse(event.flags.contains(.malformed))
        XCTAssertEqual(event.host, "storm-09")
        XCTAssertEqual(event.time(by: .senderTime), event.recvNanos, "with no sender time, it orders by receive time")
    }

    func testTimestampBeforeTwentyTwentyIsTreatedAsNoClock() {
        let event = parse("<134>1 1970-01-01T00:00:04.000000Z storm-09 stormpump - - - early boot")
        XCTAssertNil(event.sentNanos)
        XCTAssertTrue(event.flags.contains(.clockUnset))
    }

    func testRecognisesACollapsedRepeat() {
        let event = parse("<133>1 2026-08-24T21:47:11.000000Z storm-01 stormpump - - - last message repeated 17 times")
        XCTAssertTrue(event.flags.contains(.repeatNotice))
        XCTAssertEqual(event.repeated, 17)
        XCTAssertTrue(event.flags.isNodeNotice)
    }

    func testRecognisesARateLimitNotice() {
        let event = parse("<132>1 2026-08-24T21:47:11.000000Z storm-01 stormpump - - - 412 messages dropped — over 200 lines/s")
        XCTAssertTrue(event.flags.contains(.rateLimitNotice))
        XCTAssertEqual(event.repeated, 412)
    }

    func testAnOrdinaryMessageStartingWithADigitIsNotARateLimitNotice() {
        let event = parse("<134>1 2026-08-24T21:47:11.000000Z storm-01 stormblock - - - 3 replicas online")
        XCTAssertFalse(event.flags.isNodeNotice)
        XCTAssertNil(event.repeated)
    }

    /// The spec's open questions put a sequence number and a signature in
    /// structured data. Skipping it correctly today is what keeps that from
    /// being a parser rewrite later.
    func testSkipsStructuredDataIncludingEscapedBrackets() {
        let event = parse(#"<134>1 2026-08-24T21:47:11.000000Z storm-01 stormpump - - [origin seq="41" note="a \] bracket"][sig s="abc"] volume attached"#)
        XCTAssertFalse(event.flags.contains(.malformed))
        XCTAssertEqual(event.message, "volume attached")
    }

    func testRejectsUnterminatedStructuredDataRatherThanGuessing() {
        let event = parse(#"<134>1 2026-08-24T21:47:11.000000Z storm-01 stormpump - - [origin seq="41" message"#)
        XCTAssertTrue(event.flags.contains(.malformed), "an unfinished element is not a message")
    }

    func testStripsTheTrailingNewlineAndTheMessageBOM() {
        let event = parse("<134>1 2026-08-24T21:47:11.000000Z storm-01 kernel - - - \u{FEFF}hello\n")
        XCTAssertEqual(event.message, "hello")
    }

    func testRejectsAnOutOfRangePRI() {
        XCTAssertTrue(parse("<999>1 2026-08-24T21:47:11.000000Z h t - - - x").flags.contains(.malformed))
        XCTAssertTrue(parse("<>1 2026-08-24T21:47:11.000000Z h t - - - x").flags.contains(.malformed))
    }

    func testEmptyMessageIsStillAnEvent() {
        let event = parse("<134>1 2026-08-24T21:47:11.000000Z storm-01 kernel - - - ")
        XCTAssertFalse(event.flags.contains(.malformed))
        XCTAssertEqual(event.message, "")
    }

    func testHostnameNilValueFallsBackToTheSourceAddress() {
        let event = parse("<134>1 2026-08-24T21:47:11.000000Z - kernel - - - x", from: "198.51.100.3")
        XCTAssertEqual(event.host, "198.51.100.3")
    }
}
