import Foundation

/// A syslog severity, as it appears in the PRI of an RFC 5424 frame.
///
/// The node derives these from the text of the line — `ERROR`/`FATAL` become
/// `.error`, `WARN` becomes `.warning`, `DEBUG`/`TRACE` become `.debug`, and
/// anything else is `.info`. Its two notices about its own volume are
/// `.notice` (a collapsed repeat) and `.warning` (a rate-limit drop).
public enum Severity: UInt8, CaseIterable, Comparable, Codable, Sendable {
    case emergency = 0
    case alert     = 1
    case critical  = 2
    case error     = 3
    case warning   = 4
    case notice    = 5
    case info      = 6
    case debug     = 7

    /// Lower raw value is more severe, so ordering is inverted from the raw value.
    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue > rhs.rawValue
    }

    public var label: String {
        switch self {
        case .emergency: return "emergency"
        case .alert:     return "alert"
        case .critical:  return "critical"
        case .error:     return "error"
        case .warning:   return "warning"
        case .notice:    return "notice"
        case .info:      return "info"
        case .debug:     return "debug"
        }
    }

    /// Fixed-width form, so a column of them lines up without a monospaced font.
    public var short: String {
        switch self {
        case .emergency: return "EMRG"
        case .alert:     return "ALRT"
        case .critical:  return "CRIT"
        case .error:     return "ERR "
        case .warning:   return "WARN"
        case .notice:    return "NOTE"
        case .info:      return "INFO"
        case .debug:     return "DBUG"
        }
    }

    /// The whole fleet view collapses to this: is anything wrong on that node?
    public var isProblem: Bool { rawValue <= Severity.warning.rawValue }

    public init(clamping raw: Int) {
        self = Severity(rawValue: UInt8(max(0, min(7, raw)))) ?? .info
    }
}

/// `local0`, which is what a stormcos node emits under.
public let defaultFacility: UInt8 = 16
