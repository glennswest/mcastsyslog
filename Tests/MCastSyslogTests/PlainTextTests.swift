import XCTest
@testable import MCastSyslog

/// Real nodes emit coloured output — `stormpump` forwards a workload's stdout
/// as it was written. The stored message keeps the escapes, because that is
/// what the node sent; these tests are about what a person is shown.
final class PlainTextTests: XCTestCase {

    func testStripsTheColoursARealNodeSends() {
        let coloured = "\u{1B}[33m WARN\u{1B}[0m \u{1B}[2msbregistry::stormblock\u{1B}[0m\u{1B}[2m:\u{1B}[0m no API token"
        XCTAssertEqual(PlainText.strip(coloured), " WARN sbregistry::stormblock: no API token")
    }

    func testLeavesAnOrdinaryLineExactlyAlone() {
        let plain = "EXT4-fs (ublkb0): bad block size 1024"
        XCTAssertEqual(PlainText.strip(plain), plain)
        XCTAssertFalse(PlainText.containsControlSequences(plain))
    }

    func testKeepsTextThatMerelyLooksLikeAnEscape() {
        // Brackets and digits are ordinary in a log line. Only a real ESC counts.
        let text = "BIOS-e820: [mem 0x0000000000100000-0x000000007b8ebfff] usable [33m]"
        XCTAssertEqual(PlainText.strip(text), text)
    }

    func testHandlesEveryShapeOfSequenceWithoutEatingTheMessage() {
        XCTAssertEqual(PlainText.strip("\u{1B}[1;31mred\u{1B}[0m"), "red")
        XCTAssertEqual(PlainText.strip("\u{1B}[2Kcleared"), "cleared")
        XCTAssertEqual(PlainText.strip("\u{1B}]0;a title\u{07}after"), "after", "OSC ends at BEL")
        XCTAssertEqual(PlainText.strip("\u{1B}]0;a title\u{1B}\\after"), "after", "OSC ends at ST")
        XCTAssertEqual(PlainText.strip("a\u{1B}Mb"), "ab", "a two-character escape")
    }

    func testDropsStrayControlsButKeepsTabs() {
        XCTAssertEqual(PlainText.strip("a\u{0}b\u{07}c"), "abc")
        XCTAssertEqual(PlainText.strip("a\tb"), "a\tb", "a tab is layout, not noise")
    }

    func testAnUnterminatedSequenceDoesNotSwallowTheRestOfTheLine() {
        // A truncated frame can end mid-escape. Losing the message would be
        // worse than showing a little less of it.
        XCTAssertEqual(PlainText.strip("before\u{1B}"), "before")
        XCTAssertEqual(PlainText.strip("before\u{1B}[38;5"), "before")
    }

    func testTheExportCarriesBothFormsOnlyWhenTheyDiffer() {
        let coloured = LogEvent(recvNanos: 1, sentNanos: nil, host: "h", tag: "w0",
                                severity: .warning, source: "s",
                                message: "\u{1B}[33mWARN\u{1B}[0m something")
        let object = ExportFormatter.json(coloured)
        XCTAssertEqual(object["message"] as? String, coloured.message, "verbatim, as the node sent it")
        XCTAssertEqual(object["message_plain"] as? String, "WARN something")

        let ordinary = LogEvent(recvNanos: 1, sentNanos: nil, host: "h", tag: "w0",
                                severity: .info, source: "s", message: "nothing to strip")
        XCTAssertNil(ExportFormatter.json(ordinary)["message_plain"],
                     "a second copy of every line is not worth sending when it is the same line")
    }

    func testPlainTextExportIsReadable() {
        let event = LogEvent(recvNanos: 1_787_608_031_000_000_000, sentNanos: nil, host: "storm-01",
                             tag: "w0", severity: .warning, source: "s",
                             message: "\u{1B}[33mWARN\u{1B}[0m disk is filling")
        let line = ExportFormatter.textLine(event)
        XCTAssertTrue(line.contains("WARN disk is filling"))
        XCTAssertFalse(line.contains("\u{1B}"), "an export for pasting into an issue must not carry escapes")
    }
}
