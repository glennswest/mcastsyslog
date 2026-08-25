import SwiftUI

/// How a severity looks. System colours throughout, so the whole thing follows
/// the user's appearance and accent settings without a palette to maintain.
public extension Severity {
    var color: Color {
        switch self {
        case .emergency, .alert, .critical: return Color(nsColor: .systemPurple)
        case .error:   return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .notice:  return Color(nsColor: .systemYellow)
        case .info:    return Color(nsColor: .secondaryLabelColor)
        case .debug:   return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// The message itself stays readable at every level; only the badge is
    /// coloured. A log where half the lines are dimmed is a log you stop reading.
    var messageColor: Color {
        switch self {
        case .emergency, .alert, .critical, .error: return Color(nsColor: .labelColor)
        case .debug: return Color(nsColor: .secondaryLabelColor)
        default: return Color(nsColor: .labelColor)
        }
    }

    var symbol: String {
        switch self {
        case .emergency, .alert, .critical: return "exclamationmark.octagon.fill"
        case .error:   return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .notice:  return "bell.fill"
        case .info:    return "info.circle"
        case .debug:   return "ant"
        }
    }
}

/// The fixed-width severity badge in the log's left gutter.
struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        Text(severity.short.trimmingCharacters(in: .whitespaces))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(severity == .info || severity == .debug ? severity.color : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(severity == .info || severity == .debug
                          ? severity.color.opacity(0.12)
                          : severity.color)
            )
            .frame(width: 46, alignment: .leading)
            .help(severity.label)
    }
}

/// A small labelled chip. Used for tags, flags and active filters.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Color(nsColor: .secondaryLabelColor)
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .help(help ?? text)
    }
}
