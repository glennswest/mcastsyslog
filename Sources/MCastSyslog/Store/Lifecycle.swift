import Foundation

/// A point in a node's life, derived from the stream rather than asked for.
///
/// Nothing here queries a node. Every marker is something the wire already
/// says, read carefully:
///
/// - A node syncs NTP in the initramfs, before the root filesystem is mounted,
///   and sends the nil timestamp until it has. The frame where that stops is
///   therefore the moment the clock came up — a real, dated point in the boot,
///   and the most precise one available from outside.
/// - A node that goes quiet and comes back has been restarted, or partitioned.
///   Either way the run before is over.
/// - A node whose sender time steps backwards has had its clock reset, which
///   for a node that syncs at boot means it has booted.
/// - Severity 0–2 is the node saying something has gone badly wrong. That is
///   not inference; that is the node's own account.
public enum LifecycleMarker: String, Codable, Sendable, CaseIterable {
    /// The kernel's own boot banner. Not inferred from anything — the kernel
    /// prints `Linux version …` exactly once, at the start of every boot, and
    /// that is the most reliable boot marker there is.
    case kernelBoot = "kernel_boot"
    /// The first thing heard from a node, or the first after a silence.
    case boot
    /// The nil timestamp stopped: NTP came up in the initramfs.
    case clockSync = "clock_sync"
    /// The sender's clock stepped backwards — a reset, which at boot is a boot.
    case clockReset = "clock_reset"
    /// Severity 0–2. The node's own account of something going badly wrong.
    case fault
    /// The node stopped talking, and has not started again.
    case silence

    public var label: String {
        switch self {
        case .kernelBoot: return "kernel booted"
        case .boot: return "boot"
        case .clockSync: return "clock came up"
        case .clockReset: return "clock reset"
        case .fault: return "fault"
        case .silence: return "went quiet"
        }
    }

    public var symbol: String {
        switch self {
        case .kernelBoot: return "power.circle.fill"
        case .boot: return "power"
        case .clockSync: return "clock.badge.checkmark"
        case .clockReset: return "clock.arrow.circlepath"
        case .fault: return "exclamationmark.octagon"
        case .silence: return "moon.zzz"
        }
    }
}

/// How a run ended. The distinction the viewer can honestly make is narrow, and
/// it is drawn narrowly on purpose.
public enum RunEnding: String, Codable, Sendable {
    /// Still talking.
    case running
    /// It stopped because it booted again. The run ended in a restart.
    case rebooted
    /// It stopped, and the last thing it said was a fault. This is as close to
    /// "it crashed" as anything outside the node can honestly get: the node
    /// said something was badly wrong and then stopped saying anything.
    case faulted
    /// It stopped while it was talking steadily and said nothing about why.
    /// A crash, a power cut and a severed cable look identical from here, and
    /// this does not pretend to tell them apart.
    case cutOff = "cut_off"
    /// It stopped, having been barely talking anyway. Probably nothing.
    case quiet

    public var label: String {
        switch self {
        case .running: return "running"
        case .rebooted: return "ended in a reboot"
        case .faulted: return "stopped after a fault"
        case .cutOff: return "stopped mid-stream"
        case .quiet: return "went quiet"
        }
    }
}

public struct LifecycleEvent: Identifiable, Sendable {
    public var id: Int64
    public var marker: LifecycleMarker
    /// True when the node said this happened, rather than the viewer having
    /// worked it out from silence or a clock moving. A stated marker is worth
    /// more than an inferred one and is preferred wherever the two compete.
    public var stated: Bool = false
    public var host: String
    public var recvNanos: Int64
    public var sentNanos: Int64?
    public var severity: Severity
    public var message: String
    /// Only on `boot` and `silence`: how long the node was quiet.
    public var gapNanos: Int64?

    /// Whether this marker begins a run.
    public var startsARun: Bool { marker == .kernelBoot || marker == .boot }

    public var timeNanos: Int64 { sentNanos ?? recvNanos }
}

/// One continuous period of a node talking.
public struct NodeRun: Identifiable, Sendable {
    public var host: String
    public var startNanos: Int64
    public var lastNanos: Int64
    public var events: Int64
    public var worst: Severity
    public var ending: RunEnding
    public var startedWithoutAClock: Bool
    public var clockSyncNanos: Int64?
    public var faults: Int64

    public var id: String { "\(host)/\(startNanos)" }
    public var durationNanos: Int64 { max(0, lastNanos - startNanos) }
}

/// The thresholds that decide what counts as a boundary.
///
/// They are settings rather than constants because the right answer depends on
/// how chatty the fleet is: a node that says something once a minute is not
/// silent after 60 seconds, and one that talks continuously is.
public struct LifecyclePolicy: Equatable, Sendable {
    /// Silence longer than this ends a run.
    public var gapNanos: Int64
    /// A sender clock stepping back further than this is a reset, not jitter.
    public var clockBackstepNanos: Int64
    /// A run talking at least this fast when it stopped was cut off rather than
    /// having quietly wound down.
    public var busyRatePerSecond: Double

    public static let `default` = LifecyclePolicy(
        gapNanos: 90 * 1_000_000_000,
        clockBackstepNanos: 30 * 1_000_000_000,
        busyRatePerSecond: 0.2
    )

    public init(gapNanos: Int64, clockBackstepNanos: Int64, busyRatePerSecond: Double) {
        self.gapNanos = gapNanos
        self.clockBackstepNanos = clockBackstepNanos
        self.busyRatePerSecond = busyRatePerSecond
    }
}

public struct LifecycleReport: Sendable {
    public var markers: [LifecycleEvent] = []
    public var runs: [NodeRun] = []
    /// True when the scan hit its row ceiling — the report covers less than was
    /// asked for, and says so rather than reading as complete.
    public var truncated: Bool = false
    public var fromNanos: Int64 = 0
    public var toNanos: Int64 = 0
}
