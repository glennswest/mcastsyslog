import XCTest
@testable import MCastSyslog

/// The fixtures here are shaped like the traffic this was built against: a node
/// that boots repeatedly, runs ntpd, and comes up without a hostname before it
/// has one. Every assertion corresponds to something the detection originally
/// got wrong.
final class LifecycleTests: XCTestCase {

    private var directory: URL!
    private var store: EventStore!
    private var reader: EventReader!

    private let base: Int64 = 1_787_000_000_000_000_000
    private let second: Int64 = 1_000_000_000

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcastsyslog-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try EventStore(path: directory.appendingPathComponent("events.sqlite3").path)
        reader = try store.makeReader()
    }

    override func tearDownWithError() throws {
        reader = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(
        at offset: Int64, host: String = "storm-01", tag: String = "kernel",
        severity: Severity = .info, message: String, sentOffset: Int64? = nil,
        flags: EventFlags = []
    ) -> LogEvent {
        LogEvent(
            recvNanos: base + offset,
            sentNanos: flags.contains(.clockUnset) ? nil : base + (sentOffset ?? offset),
            host: host, tag: tag, severity: severity, flags: flags,
            source: "203.0.113.11", message: message)
    }

    /// A boot the kernel announced, which is the only kind that is not a guess.
    private func bootSequence(at offset: Int64, host: String = "storm-01") -> [LogEvent] {
        [
            event(at: offset, host: host, message: "Linux version 6.17.1-300.fc43.x86_64"),
            event(at: offset + second / 5, host: host, tag: "stormblock", message: "attaching volumes"),
            event(at: offset + second / 3, host: host, tag: "registry", severity: .warning, message: "no API token"),
            event(at: offset + 30 * second, host: host, tag: "stormpump", message: "workloads started"),
        ]
    }

    // MARK: - Boots

    func testTheKernelBannerIsAStatedBoot() throws {
        try store.insert(bootSequence(at: 0))
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)

        let boots = report.markers.filter { $0.marker == .kernelBoot }
        XCTAssertEqual(boots.count, 1)
        XCTAssertTrue(boots[0].stated, "the kernel said so; nothing was inferred")
        XCTAssertEqual(boots[0].host, "storm-01")
    }

    func testRepeatedRebootsAreEachFound() throws {
        // The node this was built against rebooted eleven times in an hour.
        var events: [LogEvent] = []
        for boot in 0..<5 { events += bootSequence(at: Int64(boot) * 300 * second) }
        try store.insert(events)

        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        XCTAssertEqual(report.markers.filter { $0.marker == .kernelBoot }.count, 5)
        XCTAssertEqual(report.runs.count, 5, "five boots is five runs")
    }

    func testARunEndedByAnotherBootIsAReboot() throws {
        try store.insert(bootSequence(at: 0) + bootSequence(at: 300 * second))
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)

        XCTAssertEqual(report.runs.first?.ending, .rebooted,
                       "a run that ended because the node booted again did not merely stop")
    }

    /// The kernel banner and the first line of userspace arrive milliseconds
    /// apart. They are one boot, not two.
    func testBootMarkersMillisecondsApartCollapseToOneRun() throws {
        try store.insert([
            event(at: 0, tag: "stormpump", message: "stormpump: logs to /run/stormpump/logs"),
            event(at: second / 50, message: "Linux version 6.17.1-300.fc43.x86_64"),
            event(at: 10 * second, tag: "stormblock", message: "attached"),
        ])
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        XCTAssertEqual(report.runs.count, 1, "one boot seen twice is still one run")
    }

    /// A node running ntpd steps its clock in the middle of a healthy run.
    /// Treating that as a reboot invented restarts that never happened.
    func testAnNTPDClockStepIsMarkedButDoesNotStartARun() throws {
        var events = bootSequence(at: 0)
        // Talking steadily, then the clock jumps backwards by a minute.
        for i in 1...20 {
            events.append(event(at: Int64(i) * 10 * second, tag: "timesync",
                                message: "ntpd: reply from 216.239.35.0"))
        }
        events.append(event(at: 210 * second, tag: "timesync",
                            message: "ntpd: stepping clock", sentOffset: 150 * second))
        try store.insert(events)

        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        XCTAssertTrue(report.markers.contains { $0.marker == .clockReset },
                      "the node's sense of time did change, and that is worth marking")
        XCTAssertEqual(report.runs.count, 1, "but it did not reboot")
    }

    /// Preferring stated boots must not discard inferred ones: doing that
    /// merged six restarts of one node into a single run.
    func testInferredBootsSurviveAlongsideAStatedOne() throws {
        try store.insert([
            event(at: 0, tag: "stormpump", message: "up"),
            // A long silence, then it speaks again: inferred boot.
            event(at: 600 * second, tag: "stormpump", message: "up again"),
            // And later, a boot the kernel announces.
            event(at: 1200 * second, message: "Linux version 6.17.1-300.fc43.x86_64"),
        ])
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        XCTAssertEqual(report.runs.count, 3,
                       "a stated boot does not mean the silences elsewhere were not boots")
    }

    func testTheClockComingUpIsItsOwnMarker() throws {
        try store.insert([
            event(at: 0, message: "Linux version 6.17.1-300.fc43.x86_64", flags: [.clockUnset]),
            event(at: second, tag: "stormpump", message: "early boot", flags: [.clockUnset]),
            event(at: 2 * second, tag: "timesync", message: "clock synchronised"),
        ])
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        let sync = report.markers.first { $0.marker == .clockSync }
        XCTAssertNotNil(sync, "the frame where the nil timestamp stops is the initramfs NTP sync")
        XCTAssertEqual(sync?.message, "clock synchronised")
    }

    // MARK: - How runs end

    func testARunThatStoppedAfterAFaultSaysSo() throws {
        var events = bootSequence(at: 0)
        events.append(event(at: 60 * second, severity: .critical, message: "quorum lost"))
        try store.insert(events)

        // Far enough in the past that the run is over.
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        XCTAssertEqual(report.runs.last?.ending, .faulted)
        XCTAssertEqual(report.runs.last?.faults, 1)
    }

    func testAFaultIsRecordedFromWhatTheNodeSaidNotInferred() throws {
        try store.insert(bootSequence(at: 0) + [
            event(at: 60 * second, severity: .emergency, message: "storage engine stopped serving"),
        ])
        let report = try reader.lifecycle(from: base - second, to: base + 3600 * second)
        let fault = report.markers.first { $0.marker == .fault }
        XCTAssertEqual(fault?.severity, .emergency)
        XCTAssertEqual(fault?.message, "storage engine stopped serving")
    }

    func testAStillTalkingNodeIsReportedAsRunning() throws {
        let now = Timestamp.now()
        try store.insert([
            LogEvent(recvNanos: now - 10 * second, sentNanos: now - 10 * second, host: "storm-01",
                     tag: "kernel", severity: .info, source: "s",
                     message: "Linux version 6.17.1-300.fc43.x86_64"),
            LogEvent(recvNanos: now - second, sentNanos: now - second, host: "storm-01",
                     tag: "stormpump", severity: .info, source: "s", message: "still here"),
        ])
        let report = try reader.lifecycle(from: now - 3600 * second, to: now + second)
        XCTAssertEqual(report.runs.last?.ending, .running)
    }

    func testGapThresholdIsAPolicyNotAConstant() throws {
        try store.insert([
            event(at: 0, tag: "stormpump", message: "a"),
            event(at: 120 * second, tag: "stormpump", message: "b"),
        ])
        let generous = LifecyclePolicy(gapNanos: 600 * second, clockBackstepNanos: 30 * second,
                                       busyRatePerSecond: 0.2)
        XCTAssertEqual(try reader.lifecycle(from: base - second, to: base + 3600 * second,
                                            policy: generous).runs.count, 1,
                       "a quiet fleet is not a rebooting one")
        XCTAssertEqual(try reader.lifecycle(from: base - second, to: base + 3600 * second).runs.count, 2)
    }
}
