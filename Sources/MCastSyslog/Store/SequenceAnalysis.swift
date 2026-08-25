import Foundation

/// A reading of a whole sequence — a boot, a run, a window of a fleet's life —
/// rather than a list of the lines in it.
///
/// The question this answers is the one you actually have at 3am: *what
/// happened, in what order, and what was unusual about it.* Every part of it is
/// derived from what the nodes already said. Nothing is asked of a node, and
/// nothing is inferred that the stream does not support — where the evidence
/// runs out, the analysis says so instead of guessing.
public struct SequenceAnalysis: Sendable {

    /// A stretch of the sequence with a character of its own.
    public struct Phase: Sendable {
        public enum Kind: String, Sendable {
            /// Before the node had a clock. This is the initramfs, by
            /// definition: the node sends the nil timestamp until NTP comes up,
            /// which happens before the root filesystem is mounted.
            case preClock = "pre_clock"
            /// Workloads still appearing for the first time. The system is
            /// coming up.
            case startup
            /// The set of workloads has stopped changing.
            case steady
            /// After the first fault.
            case degraded
        }

        public var kind: Kind
        public var startNanos: Int64
        public var endNanos: Int64
        public var events: Int64
        public var worst: Severity
        public var note: String

        public var durationNanos: Int64 { max(0, endNanos - startNanos) }
    }

    /// A workload's first appearance — the order things came up in.
    public struct Debut: Sendable {
        public var tag: String
        public var firstNanos: Int64
        /// How long after the sequence began this workload first said anything.
        public var offsetNanos: Int64
        public var lastNanos: Int64
        public var events: Int64
        public var worst: Severity
    }

    /// A silence inside the sequence. Where the time went.
    public struct Gap: Sendable {
        public var afterNanos: Int64
        public var untilNanos: Int64
        public var host: String
        /// The line immediately before the silence, which is usually what the
        /// node was doing while it was quiet.
        public var lastMessage: String
        public var durationNanos: Int64 { untilNanos - afterNanos }
    }

    /// The first time the sequence got worse.
    public struct Escalation: Sendable {
        public var severity: Severity
        public var atNanos: Int64
        public var offsetNanos: Int64
        public var host: String
        public var tag: String
        public var message: String
        public var eventId: Int64
    }

    /// Something worth pointing at, with the evidence for it.
    public struct Finding: Sendable {
        public enum Confidence: String, Sendable {
            /// The node said so.
            case stated
            /// The stream shows it directly.
            case observed
            /// Consistent with the stream, but other explanations fit.
            case suggested
        }

        public var title: String
        public var detail: String
        public var confidence: Confidence
        public var atNanos: Int64?
        public var host: String?
    }

    /// What every other node was saying around a fault. The spec's reason for
    /// multicast: one node's failure is usually visible in another node's log
    /// first, and neither node knows about the other.
    public struct Correlation: Sendable {
        public var faultId: Int64
        public var faultHost: String
        public var faultMessage: String
        public var atNanos: Int64
        public var windowSeconds: Double
        public var elsewhere: [LogEvent]
    }

    /// Events per bucket across the window — the shape of the sequence.
    public struct RateSample: Sendable {
        public var startNanos: Int64
        public var events: Int64
        public var worst: Severity
    }

    public var hosts: [String] = []
    public var fromNanos: Int64 = 0
    public var toNanos: Int64 = 0
    public var totalEvents: Int64 = 0
    public var phases: [Phase] = []
    public var debuts: [Debut] = []
    public var gaps: [Gap] = []
    public var escalations: [Escalation] = []
    public var findings: [Finding] = []
    public var correlations: [Correlation] = []
    public var rateProfile: [RateSample] = []
    /// The sum of the counts on collapsed-repeat and rate-limit notices: lines
    /// that exist on the nodes and were never put on the wire.
    public var linesHeldBack: Int64 = 0
    public var malformed: Int64 = 0
    public var clockUnset: Int64 = 0
    /// Sender-to-receive skew, sampled at the start and end of the window. A
    /// large skew that shrinks fast is a node replaying a boot's backlog, which
    /// is correct behaviour and not a fault.
    public var skewStartNanos: Int64?
    public var skewEndNanos: Int64?
    public var truncated = false
    /// True when the window was snapped to the start of the node's current run
    /// rather than used as given.
    public var alignedToRun = false

    /// The whole thing in sentences. Assembled from the fields above rather
    /// than written separately, so it cannot drift from them.
    public var narrative: [String] {
        var lines: [String] = []
        let span = Timestamp.formatInterval(toNanos - fromNanos)
        let who = hosts.count == 1 ? hosts[0] : "\(hosts.count) nodes"
        lines.append("\(totalEvents.formatted()) events from \(who) over \(span), "
                     + "from \(Timestamp.format(fromNanos, style: .full))."
                     + (alignedToRun ? " The window starts at this node's most recent boot, not where the request asked — the sequence is the run." : ""))

        if let preClock = phases.first(where: { $0.kind == .preClock }) {
            lines.append("It began without a clock — \(Timestamp.formatInterval(preClock.durationNanos)) "
                         + "of frames carrying the nil timestamp before NTP came up in the initramfs. "
                         + "Those \(preClock.events) events are ordered by when they were heard, "
                         + "which is the only ordering available for them.")
        }

        if !debuts.isEmpty {
            let order = debuts.prefix(6).map {
                "\($0.tag) at +\(Timestamp.formatInterval($0.offsetNanos))"
            }.joined(separator: ", ")
            lines.append("Workloads came up in this order: \(order)"
                         + (debuts.count > 6 ? ", and \(debuts.count - 6) more." : "."))
        }

        if let first = escalations.first {
            lines.append("The first \(first.severity.label) was at "
                         + "+\(Timestamp.formatInterval(first.offsetNanos)) on \(first.host) "
                         + "(\(first.tag)): \(PlainText.strip(first.message))")
        } else {
            lines.append("Nothing above info was said in this window.")
        }

        if let worst = gaps.first, worst.durationNanos > 5_000_000_000 {
            lines.append("The longest silence was \(Timestamp.formatInterval(worst.durationNanos)) "
                         + "on \(worst.host), after: \(PlainText.strip(worst.lastMessage))")
        }

        if linesHeldBack > 0 {
            lines.append("\(linesHeldBack.formatted()) lines exist on the nodes that were never put on "
                         + "the wire — collapsed repeats and rate-limit drops. The nodes' own files have them.")
        }

        for finding in findings where finding.confidence != .suggested {
            lines.append(finding.detail)
        }

        return lines
    }
}
