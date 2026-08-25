import XCTest
@testable import MCastSyslog

final class AnalysisTests: XCTestCase {

    private var directory: URL!
    private var store: EventStore!
    private var reader: EventReader!

    private let base: Int64 = 1_787_000_000_000_000_000
    private let second: Int64 = 1_000_000_000

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcastsyslog-analysis-\(UUID().uuidString)")
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
        _ offset: Int64, host: String = "storm-01", tag: String = "kernel",
        severity: Severity = .info, message: String = "line",
        flags: EventFlags = [], repeated: Int? = nil, sentOffset: Int64? = nil
    ) -> LogEvent {
        LogEvent(recvNanos: base + offset,
                 sentNanos: flags.contains(.clockUnset) ? nil : base + (sentOffset ?? offset),
                 host: host, tag: tag, severity: severity, flags: flags, repeated: repeated,
                 source: "203.0.113.11", message: message)
    }

    /// A boot shaped like the real one this was built against.
    private func realisticBoot(host: String = "storm-01") -> [LogEvent] {
        var events = [
            event(0, host: host, message: "Linux version 6.17.1-300.fc43.x86_64"),
            event(second / 5, host: host, tag: "stormblock", message: "volumes attached"),
            event(second / 3, host: host, tag: "registry", severity: .warning,
                  message: "\u{1B}[33m WARN\u{1B}[0m no stormblockmk API token"),
            event(30 * second, host: host, tag: "stormpump", message: "workloads started"),
        ]
        for i in 1...40 {
            events.append(event(Int64(i) * second, host: host, message: "EXT4-fs: mounted"))
        }
        return events
    }

    private func analyse(hosts: Set<String> = ["storm-01"], span: Int64 = 3600) throws -> SequenceAnalysis {
        try reader.analyse(from: base - 10 * second, to: base + span * second, hosts: hosts)
    }

    // MARK: - The sequence

    func testWorkloadsAreReportedInTheOrderTheyCameUp() throws {
        try store.insert(realisticBoot())
        let a = try analyse()
        XCTAssertEqual(a.debuts.map(\.tag), ["kernel", "stormblock", "registry", "stormpump"])
        XCTAssertEqual(a.debuts[0].offsetNanos, 0, "the sequence starts at the boot")
        XCTAssertEqual(a.debuts[1].offsetNanos, second / 5)
    }

    func testTheWindowSnapsToTheBootSoTheSequenceIsTheRun() throws {
        // Hours of earlier chatter, then a boot. Asking for "the last day"
        // should analyse the run, not the day.
        var events = (1...20).map { event(Int64(-$0) * 600 * second, tag: "stormpump", message: "before") }
        events += realisticBoot()
        try store.insert(events)

        let a = try reader.analyse(from: base - 86_400 * second, to: base + 3600 * second,
                                   hosts: ["storm-01"])
        XCTAssertTrue(a.alignedToRun)
        XCTAssertEqual(a.fromNanos, base, "the boot, not where the request reached back to")
        XCTAssertFalse(a.narrative.contains { $0.contains("before") })
    }

    func testAnExplicitWindowIsNotSnapped() throws {
        try store.insert(realisticBoot())
        let a = try reader.analyse(from: base - 100 * second, to: base + 3600 * second,
                                   hosts: ["storm-01"], alignToRun: false)
        XCTAssertFalse(a.alignedToRun)
        XCTAssertEqual(a.fromNanos, base - 100 * second)
    }

    // MARK: - Phases

    func testPhasesDescribeOneNodeAndSayNothingAboutAFleet() throws {
        try store.insert(realisticBoot(host: "storm-01") + realisticBoot(host: "storm-02"))

        let one = try analyse(hosts: ["storm-01"])
        XCTAssertFalse(one.phases.isEmpty)

        let both = try analyse(hosts: [])
        XCTAssertTrue(both.phases.isEmpty,
                      "several nodes' sequences overlaid is not one startup")
        XCTAssertEqual(both.hosts.count, 2)
    }

    func testPhaseEventCountsAreCountedNotEstimated() throws {
        try store.insert(realisticBoot())
        let a = try analyse()
        let counted = a.phases.reduce(Int64(0)) { $0 + $1.events }
        XCTAssertGreaterThan(counted, 0)
        XCTAssertLessThanOrEqual(counted, a.totalEvents,
                                 "a phase reporting zero because of bucket arithmetic is worse than one that costs a query")
    }

    /// A tag that appears once, hours in, is not the system still starting up.
    func testAOneOffTagDoesNotStretchStartupAcrossTheWholeWindow() throws {
        var events = realisticBoot()
        events.append(event(3000 * second, tag: "mcheck", severity: .warning, message: "a single late line"))
        try store.insert(events)

        let a = try analyse(span: 3600)
        let startup = a.phases.first { $0.kind == .startup }
        XCTAssertNotNil(startup)
        XCTAssertLessThan(startup!.durationNanos, 1000 * second,
                          "startup ended when the workloads that matter had appeared")
        XCTAssertTrue(startup!.note.contains("appeared later"),
                      "and the late one is accounted for rather than ignored")
    }

    func testTheFirstFaultSplitsSteadyFromDegraded() throws {
        var events = realisticBoot()
        events.append(event(100 * second, severity: .error, message: "ublk queue reset"))
        try store.insert(events)

        let a = try analyse()
        XCTAssertTrue(a.phases.contains { $0.kind == .degraded })
        let degraded = a.phases.first { $0.kind == .degraded }!
        XCTAssertEqual(degraded.startNanos, base + 100 * second)
    }

    // MARK: - Escalations and gaps

    func testEscalationsRecordTheFirstOfEachSeverityWorstFirst() throws {
        var events = realisticBoot()
        events.append(event(50 * second, severity: .error, message: "first error"))
        events.append(event(60 * second, severity: .error, message: "second error"))
        events.append(event(70 * second, severity: .critical, message: "the critical one"))
        try store.insert(events)

        let a = try analyse()
        XCTAssertEqual(a.escalations.first?.severity, .critical, "worst first")
        let firstError = a.escalations.first { $0.severity == .error }
        XCTAssertEqual(firstError?.message, "first error", "the first, not the latest")
    }

    func testTheLongestSilenceIsFoundWithWhatWasSaidBeforeIt() throws {
        try store.insert(realisticBoot() + [
            event(500 * second, tag: "stormpump", message: "after a long quiet"),
        ])
        let a = try analyse()
        let longest = a.gaps.first
        XCTAssertNotNil(longest)
        XCTAssertGreaterThan(longest!.durationNanos, 400 * second)
        XCTAssertEqual(longest!.lastMessage, "EXT4-fs: mounted", "what it was doing when it went quiet")
    }

    // MARK: - Findings

    func testABacklogReplayIsNamedRatherThanLeftLookingLikeAFault() throws {
        // Sender times spread over an hour, all received within a second: a node
        // whose network came up and sent the backlog at once.
        var events: [LogEvent] = [event(0, message: "Linux version 6.17.1-300.fc43.x86_64",
                                        sentOffset: -3600 * second)]
        for i in 1...50 {
            events.append(event(Int64(i) * second / 50, message: "replayed \(i)",
                                sentOffset: -3600 * second + Int64(i) * 60 * second))
        }
        try store.insert(events)

        let a = try analyse()
        XCTAssertTrue(a.findings.contains { $0.title.contains("backlog") },
                      "correct behaviour, and the analysis should say so rather than let it read as a fault")
    }

    func testHeldBackLinesAreReportedAsFactsTheNodeStated() throws {
        try store.insert(realisticBoot() + [
            event(200 * second, tag: "stormpump", severity: .notice,
                  message: "last message repeated 40 times",
                  flags: [.repeatNotice], repeated: 40),
            event(210 * second, tag: "stormpump", severity: .warning,
                  message: "900 messages dropped — over 200 lines/s",
                  flags: [.rateLimitNotice], repeated: 900),
        ])
        let a = try analyse()
        XCTAssertEqual(a.linesHeldBack, 940)
        let finding = a.findings.first { $0.title.contains("never reached the wire") }
        XCTAssertEqual(finding?.confidence, .stated, "the node said so")
    }

    func testANodeWithNoHostnameYetIsPointedAt() throws {
        try store.insert(realisticBoot(host: "(none)"))
        let a = try analyse(hosts: [])
        XCTAssertTrue(a.findings.contains { $0.title.contains("hostname") },
                      "Linux reports `(none)` before the hostname is set — that is early boot")
    }

    func testEveryFindingCarriesHowMuchItIsWorth() throws {
        try store.insert(realisticBoot() + [
            event(200 * second, message: "garbled", flags: [.malformed]),
        ])
        let a = try analyse()
        XCTAssertFalse(a.findings.isEmpty)
        for finding in a.findings {
            XCTAssertFalse(finding.detail.isEmpty, "\(finding.title) asserts something with no evidence")
        }
    }

    // MARK: - Correlations

    func testAFaultCarriesWhatEveryOtherNodeWasSaying() throws {
        try store.insert(realisticBoot(host: "storm-01") + realisticBoot(host: "storm-02") + [
            event(100 * second, host: "storm-01", severity: .error, message: "quorum lost"),
            event(100 * second + second / 2, host: "storm-02", severity: .warning,
                  message: "peer storm-01 unreachable"),
        ])
        let a = try analyse(hosts: [])
        let correlation = a.correlations.first { $0.faultMessage == "quorum lost" }
        XCTAssertNotNil(correlation, "the whole reason multicast is worth having")
        XCTAssertTrue(correlation!.elsewhere.contains { $0.host == "storm-02" })
        XCTAssertFalse(correlation!.elsewhere.contains { $0.host == "storm-01" },
                       "`elsewhere` means elsewhere")
    }

    // MARK: - The narrative

    func testTheNarrativeReadsWithoutTerminalEscapes() throws {
        try store.insert(realisticBoot())
        let a = try analyse()
        for line in a.narrative {
            XCTAssertFalse(line.contains("\u{1B}"), "a narrative full of escape codes is unreadable")
        }
        XCTAssertTrue(a.narrative.contains { $0.contains("no stormblockmk API token") })
    }

    func testAnEmptyWindowSaysNothingRatherThanInventingSomething() throws {
        let a = try analyse()
        XCTAssertEqual(a.totalEvents, 0)
        XCTAssertTrue(a.phases.isEmpty)
        XCTAssertTrue(a.debuts.isEmpty)
        XCTAssertTrue(a.findings.isEmpty)
    }
}
