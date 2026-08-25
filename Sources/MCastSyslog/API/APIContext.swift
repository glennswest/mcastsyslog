import Foundation

/// Everything the REST API is allowed to touch, and nothing else.
///
/// Note what is absent: there is no reference to the receiver's socket, no way
/// to transmit, and no mutating operation of any kind. The API can read the
/// store and report status. That is the whole surface, and it is deliberate —
/// an HTTP endpoint that could reach a node would be a much easier mistake to
/// make than the one the spec is guarding against.
public final class APIContext: @unchecked Sendable {

    /// The settings the API reports, snapshotted so it never reads main-actor
    /// state from its own queue.
    public struct Snapshot: Sendable {
        public var endpoint: ListenEndpoint = .default
        public var retention: RetentionPolicy = .default
        /// Whether the one destructive endpoint is switched on at all.
        public var allowClearing: Bool = false
        /// Whether the API is reachable from other machines, which is what
        /// makes clearing over it refuse regardless of the switch above.
        public var servesRemotely: Bool = false

        public init() {}
    }

    private let store: EventStore
    private let receiver: MulticastReceiver
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var readers: [EventReader] = []

    /// Live events, for the SSE endpoint.
    public let live = LiveBroadcast()

    public init(store: EventStore, receiver: MulticastReceiver) {
        self.store = store
        self.receiver = receiver
    }

    public func update(_ snapshot: Snapshot) {
        lock.lock(); self.snapshot = snapshot; lock.unlock()
    }

    public var settings: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public var receiverStatus: ReceiverStatus { receiver.currentStatus }

    public func storeStats() throws -> StoreStats { try store.stats() }

    /// What the store has recorded about itself — including what last deleted
    /// from it, and why.
    public func storeNotes() throws -> [String: String] { try store.notes() }

    /// The only thing the API can change, and only when three separate guards
    /// in `APIRouter.clear` all agree. Nothing here touches a node.
    public func clearStore() throws {
        try store.deleteAll(reason: "over the REST API")
        onStoreCleared?()
    }

    /// Set by the app so the window empties with the store rather than showing
    /// rows that no longer exist.
    public var onStoreCleared: (() -> Void)?

    /// Borrow a reader, and put it back. A handful of connections share a few
    /// connections to the database rather than opening one per request; a reader
    /// is cheap but not free, and requests here are not a hot path.
    public func withReader<T>(_ body: (EventReader) throws -> T) throws -> T {
        let reader = try checkout()
        defer { checkin(reader) }
        return try body(reader)
    }

    private static let poolLimit = 4

    private func checkout() throws -> EventReader {
        lock.lock()
        if let reader = readers.popLast() {
            lock.unlock()
            return reader
        }
        lock.unlock()
        return try store.makeReader()
    }

    private func checkin(_ reader: EventReader) {
        lock.lock()
        if readers.count < Self.poolLimit { readers.append(reader) }
        lock.unlock()
    }
}

/// Fan-out of live events to whatever Server-Sent Events streams are open.
///
/// Subscribers are pushed to, never polled, and a subscriber that has gone away
/// is dropped rather than retried. Nothing here can apply back-pressure to the
/// receiver: a slow HTTP client is the HTTP client's problem, not the wire's.
public final class LiveBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: (handle: EventStreamHandle, filter: FilterState, ordering: TimeOrdering)] = [:]

    public init() {}

    public var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    public func subscribe(_ handle: EventStreamHandle, filter: FilterState, ordering: TimeOrdering) {
        lock.lock()
        subscribers[ObjectIdentifier(handle)] = (handle, filter, ordering)
        lock.unlock()
        handle.onClose = { [weak self] in self?.unsubscribe(handle) }
    }

    public func unsubscribe(_ handle: EventStreamHandle) {
        lock.lock()
        subscribers.removeValue(forKey: ObjectIdentifier(handle))
        lock.unlock()
    }

    /// Called from the receiver's delivery queue with a batch that has already
    /// been written to the store.
    public func publish(_ events: [LogEvent]) {
        lock.lock()
        let current = Array(subscribers.values)
        lock.unlock()
        guard !current.isEmpty else { return }

        let now = Timestamp.now()
        for subscriber in current {
            guard !subscriber.handle.isClosed else {
                unsubscribe(subscriber.handle)
                continue
            }
            for event in events where subscriber.filter.matches(event, ordering: subscriber.ordering, now: now) {
                subscriber.handle.send(event: "log", json: ExportFormatter.json(event))
            }
        }
    }

    public func closeAll() {
        lock.lock()
        let current = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for subscriber in current { subscriber.handle.close() }
    }
}
