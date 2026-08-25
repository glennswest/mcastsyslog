import Foundation

/// Facts about a frame that the viewer must not lose, and must render
/// distinctly. They are facts about the node, not noise.
public struct EventFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// The frame did not parse as RFC 5424 and is kept verbatim. Never dropped:
    /// a viewer that hides what it cannot parse hides the interesting failures.
    public static let malformed = EventFlags(rawValue: 1 << 0)
    /// The sender sent the NILVALUE `-` for its timestamp, or a timestamp before
    /// 2020. The node is saying its clock is not real rather than inventing a
    /// plausible time; this event is ordered by receive time.
    public static let clockUnset = EventFlags(rawValue: 1 << 1)
    /// `last message repeated N time(s)` — the node collapsed a run.
    public static let repeatNotice = EventFlags(rawValue: 1 << 2)
    /// `N message(s) dropped — over 200 lines/s` — the node's token bucket ran dry.
    public static let rateLimitNotice = EventFlags(rawValue: 1 << 3)

    public var isNodeNotice: Bool {
        !self.isDisjoint(with: [.repeatNotice, .rateLimitNotice])
    }
}

/// One datagram, parsed.
///
/// Both times are kept. They differ, and the difference is information: a node
/// replaying a boot's backlog after its network came up sends an hour of lines
/// in a second, which is correct behaviour and not a fault.
public struct LogEvent: Identifiable, Hashable, Sendable {
    /// Assigned by the store on insert. Zero means "not stored yet".
    public var id: Int64
    /// Receive time at the viewer, Unix nanoseconds. Monotonic here, never nil,
    /// and the only ordering a node with a wrong clock cannot perturb.
    public var recvNanos: Int64
    /// The sender's own timestamp, Unix nanoseconds; nil when it sent `-`.
    public var sentNanos: Int64?
    public var host: String
    public var tag: String
    public var severity: Severity
    public var facility: UInt8
    public var flags: EventFlags
    /// N, on a collapsed-repeat or rate-limit notice.
    public var repeated: Int?
    /// The address the datagram actually arrived from, which is not necessarily
    /// what the frame claims its hostname is.
    public var source: String
    public var message: String
    /// The frame verbatim. Kept only when it did not parse.
    public var raw: Data?

    public init(
        id: Int64 = 0,
        recvNanos: Int64,
        sentNanos: Int64? = nil,
        host: String,
        tag: String,
        severity: Severity,
        facility: UInt8 = defaultFacility,
        flags: EventFlags = [],
        repeated: Int? = nil,
        source: String,
        message: String,
        raw: Data? = nil
    ) {
        self.id = id
        self.recvNanos = recvNanos
        self.sentNanos = sentNanos
        self.host = host
        self.tag = tag
        self.severity = severity
        self.facility = facility
        self.flags = flags
        self.repeated = repeated
        self.source = source
        self.message = message
        self.raw = raw
    }

    /// The time to sort and display by, under the given ordering. Sender time
    /// falls back to receive time when the node had no clock.
    public func time(by ordering: TimeOrdering) -> Int64 {
        switch ordering {
        case .senderTime: return sentNanos ?? recvNanos
        case .receiveTime: return recvNanos
        }
    }

    /// How far the sender's clock is from ours, in nanoseconds, when it has one.
    public var skewNanos: Int64? {
        guard let sentNanos else { return nil }
        return recvNanos - sentNanos
    }

    /// The spec's threshold for "these disagree enough to say so".
    public var hasNotableSkew: Bool {
        guard let skew = skewNanos else { return false }
        return abs(skew) > 5_000_000_000
    }
}

/// Which of the two times the viewer orders by. Sender time is the default,
/// because it is the order things happened on the node.
public enum TimeOrdering: String, CaseIterable, Codable, Sendable {
    case senderTime
    case receiveTime

    public var label: String {
        switch self {
        case .senderTime: return "Sender time"
        case .receiveTime: return "Receive time"
        }
    }
}
