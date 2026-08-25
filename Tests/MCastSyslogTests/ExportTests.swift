import XCTest
@testable import MCastSyslog

/// The export encoding is a format, not an implementation detail — the point of
/// writing it down in docs/EXPORT.md is that must-gather can produce the same
/// shape and the two stay interchangeable. So it has to round-trip exactly.
final class ExportTests: XCTestCase {

    func testAnEventRoundTripsThroughTheJSONEncoding() throws {
        let original = LogEvent(
            recvNanos: 1_787_003_231_123_456_000,
            sentNanos: 1_787_003_231_000_001_000,
            host: "storm-09", tag: "stormpump", severity: .error, facility: 16,
            flags: [.malformed, .rateLimitNotice], repeated: 412,
            source: "192.168.1.9", message: "ERROR quorum lost",
            raw: Data([0x01, 0xFF, 0x00])
        )

        let object = ExportFormatter.json(original)
        let data = try JSONSerialization.data(withJSONObject: object)
        let decodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let restored = try XCTUnwrap(ExportFormatter.event(from: decodedObject, fallbackReceive: 0))

        XCTAssertEqual(restored.recvNanos, original.recvNanos)
        XCTAssertEqual(restored.sentNanos, original.sentNanos)
        XCTAssertEqual(restored.host, original.host)
        XCTAssertEqual(restored.tag, original.tag)
        XCTAssertEqual(restored.severity, original.severity)
        XCTAssertEqual(restored.facility, original.facility)
        XCTAssertEqual(restored.flags, original.flags)
        XCTAssertEqual(restored.repeated, original.repeated)
        XCTAssertEqual(restored.source, original.source)
        XCTAssertEqual(restored.message, original.message)
        XCTAssertEqual(restored.raw, original.raw)
    }

    func testAClocklessEventDoesNotGainATimeInTheExport() throws {
        let event = LogEvent(recvNanos: 42, sentNanos: nil, host: "h", tag: "t",
                             severity: .info, flags: [.clockUnset], source: "s", message: "m")
        let object = ExportFormatter.json(event)
        XCTAssertNil(object["sent_ns"])
        XCTAssertNil(object["sent"])

        let restored = try XCTUnwrap(ExportFormatter.event(from: object, fallbackReceive: 0))
        XCTAssertNil(restored.sentNanos)
        XCTAssertTrue(restored.flags.contains(.clockUnset))
    }

    func testWritingAndReadingABundleBackGivesTheSameEvents() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcastsyslog-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try EventStore(path: directory.appendingPathComponent("events.sqlite3").path)
        let base: Int64 = 1_787_000_000_000_000_000
        let originals = (0..<50).map { i in
            LogEvent(recvNanos: base + Int64(i) * 1_000_000, sentNanos: base + Int64(i) * 1_000_000,
                     host: "storm-0\(i % 3)", tag: "stormblock",
                     severity: i % 7 == 0 ? .error : .info,
                     source: "10.0.0.1", message: "line \(i) — vol-\(i)")
        }
        try store.insert(originals)

        let url = directory.appendingPathComponent("bundle.jsonl")
        var query = EventQuery()
        query.limit = Int.max
        let written = try ExportService.write(
            to: url, format: .jsonl, query: query, filter: FilterState(),
            endpoint: .default, ordering: .senderTime, reader: try store.makeReader())
        XCTAssertEqual(written, 50)

        let (readBack, manifest) = try ExportService.read(url)
        XCTAssertEqual(readBack.count, 50)
        XCTAssertEqual(readBack.map(\.message), originals.map(\.message))
        XCTAssertEqual(manifest?["format"] as? String, ExportFormatter.formatIdentifier)
        XCTAssertEqual(manifest?["group"] as? String, ListenEndpoint.default.description)
    }

    func testTheManifestLineIsNotMistakenForAnEvent() throws {
        let manifest = ExportFormatter.manifest(filter: FilterState(), endpoint: .default, ordering: .senderTime)
        let inner = try XCTUnwrap(manifest["mcastsyslog"] as? [String: Any])
        XCTAssertEqual(inner["version"] as? String, AppVersion.current)
        XCTAssertNil(ExportFormatter.event(from: manifest, fallbackReceive: 0),
                     "the manifest has no message, so it can never decode as an event")
    }

    func testTextLinesCarryTheFlagsThatWouldOtherwiseBeInvisible() {
        let event = LogEvent(recvNanos: 1_787_003_231_000_000_000, sentNanos: nil,
                             host: "storm-09", tag: "kernel", severity: .error,
                             flags: [.malformed, .clockUnset], source: "s", message: "garbled")
        let line = ExportFormatter.textLine(event)
        XCTAssertTrue(line.contains("storm-09"))
        XCTAssertTrue(line.contains("ERR"))
        XCTAssertTrue(line.contains("[malformed]"))
        XCTAssertTrue(line.contains("[clock unset]"))
    }
}
