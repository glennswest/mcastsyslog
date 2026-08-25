import Foundation

/// Unix-nanosecond time, parsed and rendered without `DateFormatter`.
///
/// The wire format is a fixed grammar and the viewer renders hundreds of rows
/// on every scroll tick, so both directions are done by hand. It also keeps
/// microsecond precision, which is what the node sends and what
/// `Date`'s double seconds would quietly round away.
public enum Timestamp {

    /// 2020-01-01T00:00:00Z. The node's own threshold for "this clock is not real".
    public static let year2020: Int64 = 1_577_836_800 * 1_000_000_000

    public static func now() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    // MARK: - Parsing

    /// RFC 3339: `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM|±HHMM)`.
    public static func parseRFC3339<S: StringProtocol>(_ s: S) -> Int64? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }

        func digits(_ at: Int, _ n: Int) -> Int? {
            var v = 0
            for k in at..<(at + n) {
                guard k < b.count, b[k] >= 0x30, b[k] <= 0x39 else { return nil }
                v = v * 10 + Int(b[k] - 0x30)
            }
            return v
        }

        guard let year = digits(0, 4), b[4] == 0x2D,
              let month = digits(5, 2), b[7] == 0x2D,
              let day = digits(8, 2),
              b[10] == 0x54 || b[10] == 0x74 || b[10] == 0x20,   // 'T', 't' or a space
              let hour = digits(11, 2), b[13] == 0x3A,
              let minute = digits(14, 2), b[16] == 0x3A,
              let second = digits(17, 2)
        else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31,
              hour <= 23, minute <= 59, second <= 60          // 60: a leap second
        else { return nil }

        var i = 19
        var nanos = 0
        if i < b.count, b[i] == 0x2E || b[i] == 0x2C {        // '.' or ','
            i += 1
            var scale = 100_000_000
            var any = false
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if scale > 0 { nanos += Int(b[i] - 0x30) * scale; scale /= 10 }
                i += 1
                any = true
            }
            guard any else { return nil }
        }

        var offsetSeconds = 0
        if i < b.count {
            let c = b[i]
            if c == 0x5A || c == 0x7A {                       // 'Z' or 'z'
                i += 1
            } else if c == 0x2B || c == 0x2D {                // '+' or '-'
                let sign = c == 0x2D ? -1 : 1
                guard let oh = digits(i + 1, 2) else { return nil }
                var om = 0
                if i + 3 < b.count, b[i + 3] == 0x3A {
                    guard let m = digits(i + 4, 2) else { return nil }
                    om = m
                    i += 6
                } else if let m = digits(i + 3, 2) {
                    om = m
                    i += 5
                } else {
                    i += 3
                }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        guard i >= b.count else { return nil }                // trailing junk

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400
            + Int64(hour) * 3600 + Int64(minute) * 60 + Int64(second)
            - Int64(offsetSeconds)
        return seconds * 1_000_000_000 + Int64(nanos)
    }

    /// What a human might paste into "jump to a moment": an RFC 3339 stamp from
    /// a log line, a `YYYY-MM-DD HH:MM:SS` from a ticket, a bare date, or a raw
    /// epoch number in seconds, milliseconds, microseconds or nanoseconds.
    ///
    /// A stamp with no zone is read as local time, because that is how someone
    /// reading a ticket means it.
    public static func parseFlexible(_ input: String) -> Int64? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let ns = parseRFC3339(s) { return ns }

        // Bare epoch. The magnitude says which unit it is.
        if s.allSatisfy({ $0.isNumber }), let n = Int64(s) {
            switch s.count {
            case ...11:  return n * 1_000_000_000    // seconds
            case 12...14: return n * 1_000_000       // milliseconds
            case 15...17: return n * 1_000           // microseconds
            default:      return n                   // nanoseconds
            }
        }

        // Zoneless forms, completed to a full local timestamp.
        let padded: String
        switch s.count {
        case 10: padded = s + "T00:00:00"            // YYYY-MM-DD
        case 16: padded = s.replacingOccurrences(of: " ", with: "T") + ":00"
        default: padded = s.replacingOccurrences(of: " ", with: "T")
        }
        guard let utcNanos = parseRFC3339(padded) else { return nil }
        let offset = TimeZone.current.secondsFromGMT(
            for: Date(timeIntervalSince1970: Double(utcNanos) / 1e9))
        return utcNanos - Int64(offset) * 1_000_000_000
    }

    // MARK: - Rendering

    public enum Style {
        /// `21:47:11.123456` — the log column, where the date is in the header.
        case timeOnly
        /// `2026-08-24 21:47:11.123456`
        case full
        /// `2026-08-24T21:47:11.123456Z` — what goes into an export.
        case rfc3339UTC
    }

    public static func format(_ nanos: Int64, style: Style = .timeOnly) -> String {
        let utc = style == .rfc3339UTC
        let offset: Int64 = utc ? 0 : Int64(TimeZone.current.secondsFromGMT(
            for: Date(timeIntervalSince1970: Double(nanos) / 1e9)))
        let local = nanos + offset * 1_000_000_000

        var seconds = local / 1_000_000_000
        var sub = local % 1_000_000_000
        if sub < 0 { sub += 1_000_000_000; seconds -= 1 }

        let days = Int(floorDiv(seconds, 86_400))
        let secondOfDay = Int(seconds - Int64(days) * 86_400)
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay / 60) % 60
        let second = secondOfDay % 60
        let micros = Int(sub / 1000)

        let time = "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(micros, 6))"
        switch style {
        case .timeOnly:   return time
        case .full:       return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) \(time)"
        case .rfc3339UTC: return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(time)Z"
        }
    }

    /// `2026-08-24`, in local time — the log view's date header.
    public static func formatDay(_ nanos: Int64) -> String {
        String(format(nanos, style: .full).prefix(10))
    }

    /// A skew or an age, at the precision that makes it readable.
    public static func formatInterval(_ nanos: Int64) -> String {
        let n = abs(nanos)
        let sign = nanos < 0 ? "-" : ""
        if n < 1_000 { return "\(sign)\(n)ns" }
        if n < 1_000_000 { return String(format: "%@%.1fµs", sign, Double(n) / 1e3) }
        if n < 1_000_000_000 { return String(format: "%@%.1fms", sign, Double(n) / 1e6) }
        if n < 60_000_000_000 { return String(format: "%@%.2fs", sign, Double(n) / 1e9) }
        let seconds = n / 1_000_000_000
        if seconds < 3600 { return "\(sign)\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86_400 { return "\(sign)\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(sign)\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
    }

    // MARK: - Civil calendar
    //
    // Howard Hinnant's days_from_civil / civil_from_days: proleptic Gregorian,
    // no table, no branch on leap years, and exact for any year we will see.

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = floorDivInt(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = floorDivInt(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func floorDivInt(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
