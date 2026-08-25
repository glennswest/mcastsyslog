import Foundation
import Combine

/// Everything the user can change, persisted in `UserDefaults`.
///
/// There is deliberately no setting that could cause the viewer to transmit.
@MainActor
public final class AppSettings: ObservableObject {

    @Published public var groupAddress: String {
        didSet { defaults.set(groupAddress, forKey: Key.groupAddress) }
    }
    @Published public var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }
    @Published public var retentionGiB: Double {
        didSet { defaults.set(retentionGiB, forKey: Key.retentionGiB) }
    }
    @Published public var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }
    @Published public var ordering: TimeOrdering {
        didSet { defaults.set(ordering.rawValue, forKey: Key.ordering) }
    }
    /// How many events the live view holds. Not a retention setting — the store
    /// keeps far more; this is what the table is willing to render.
    @Published public var liveWindow: Int {
        didSet { defaults.set(liveWindow, forKey: Key.liveWindow) }
    }
    @Published public var startListeningOnLaunch: Bool {
        didSet { defaults.set(startListeningOnLaunch, forKey: Key.autoStart) }
    }
    /// The read-only REST API. Off unless asked for, and bound to loopback
    /// unless asked for that too.
    @Published public var apiEnabled: Bool {
        didSet { defaults.set(apiEnabled, forKey: Key.apiEnabled) }
    }
    @Published public var apiPort: Int {
        didSet { defaults.set(apiPort, forKey: Key.apiPort) }
    }
    /// Serving on every interface hands the whole fleet's logs to anything that
    /// can reach this Mac. Deliberate, never a default.
    @Published public var apiAllowRemote: Bool {
        didSet { defaults.set(apiAllowRemote, forKey: Key.apiAllowRemote) }
    }

    private enum Key {
        static let groupAddress = "group.address"
        static let port = "group.port"
        static let retentionGiB = "retention.gib"
        static let retentionDays = "retention.days"
        static let ordering = "view.ordering"
        static let liveWindow = "view.liveWindow"
        static let autoStart = "listen.autoStart"
        static let apiEnabled = "api.enabled"
        static let apiPort = "api.port"
        static let apiAllowRemote = "api.allowRemote"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.groupAddress: ListenEndpoint.default.address,
            Key.port: Int(ListenEndpoint.default.port),
            Key.retentionGiB: 2.0,
            Key.retentionDays: 30,
            Key.ordering: TimeOrdering.senderTime.rawValue,
            Key.liveWindow: 5000,
            Key.autoStart: true,
            Key.apiEnabled: false,
            Key.apiPort: 8514,
            Key.apiAllowRemote: false,
        ])
        groupAddress = defaults.string(forKey: Key.groupAddress) ?? ListenEndpoint.default.address
        port = defaults.integer(forKey: Key.port)
        retentionGiB = defaults.double(forKey: Key.retentionGiB)
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        ordering = TimeOrdering(rawValue: defaults.string(forKey: Key.ordering) ?? "") ?? .senderTime
        liveWindow = defaults.integer(forKey: Key.liveWindow)
        startListeningOnLaunch = defaults.bool(forKey: Key.autoStart)
        apiEnabled = defaults.bool(forKey: Key.apiEnabled)
        apiPort = defaults.integer(forKey: Key.apiPort)
        apiAllowRemote = defaults.bool(forKey: Key.apiAllowRemote)
    }

    public var endpoint: ListenEndpoint {
        ListenEndpoint(address: groupAddress, port: UInt16(clamping: port))
    }

    public var retention: RetentionPolicy {
        RetentionPolicy(
            maxBytes: Int64(retentionGiB * 1024 * 1024 * 1024),
            maxAgeNanos: Int64(retentionDays) * 86_400 * 1_000_000_000
        )
    }

    public var apiConfiguration: HTTPServer.Configuration {
        HTTPServer.Configuration(port: UInt16(clamping: apiPort), allowRemote: apiAllowRemote)
    }

    public var apiBaseURL: String {
        "http://\(apiAllowRemote ? "0.0.0.0" : "127.0.0.1"):\(apiPort)"
    }

    public func resetEndpoint() {
        groupAddress = ListenEndpoint.default.address
        port = Int(ListenEndpoint.default.port)
    }
}
