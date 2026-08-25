import Foundation

public enum AppVersion {
    /// Must match `MARKETING_VERSION` in project.yml, the changelog heading and
    /// the git tag. A mismatch between any of them is a bug.
    public static let current = "0.2.0"

    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? current
    }

    public static let name = "mcastsyslog"
    public static let summary = "A viewer for a fleet that is talking."
}
