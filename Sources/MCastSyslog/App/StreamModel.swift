import Foundation
import Combine
import SwiftUI

/// What the event table is currently showing, and how it got there.
public enum ViewState: Equatable {
    case idle
    case querying
    /// A substring search, reading messages rather than an index. The viewer
    /// says so and offers to stop, because a search that quietly took ten
    /// seconds is a search you cannot trust the result of.
    case scanning
    case cancelled
    case failed(String)
}

/// The one object the views read from.
///
/// It owns the receiver, the store and the readers, and it is the only place
/// where the background halves and the UI meet. The receive path never touches
/// this on its own thread: batches arrive on a delivery queue, are written, and
/// are then handed to the main thread in coalesced flushes.
@MainActor
public final class StreamModel: ObservableObject {

    // What the views render.
    @Published public private(set) var events: [LogEvent] = []
    @Published public private(set) var fleet: [FleetNode] = []
    @Published public private(set) var knownHosts: [String] = []
    @Published public private(set) var knownTags: [String] = []
    @Published public private(set) var receiver = ReceiverStatus()
    @Published public private(set) var storeStats = StoreStats()
    @Published public private(set) var state: ViewState = .idle
    @Published public private(set) var matchCount: Int64 = 0
    @Published public private(set) var matchCountExact = true
    @Published public private(set) var lastQueryNanos: Int64 = 0
    /// Events that arrived while the view was pinned to a moment. The count is
    /// shown rather than the events, so the ground does not move under someone
    /// reading.
    @Published public private(set) var unseen: Int = 0
    @Published public private(set) var eventsPerSecond: Double = 0
    @Published public private(set) var storeError: String?
    @Published public private(set) var apiRunning = false
    @Published public private(set) var apiError: String?

    // What the user is doing.
    @Published public var filter = FilterState() { didSet { filterChanged(from: oldValue) } }
    @Published public var isFollowing = true { didSet { if isFollowing { catchUp() } } }
    @Published public var selection: LogEvent.ID?
    @Published public var showInspector = false

    public let settings: AppSettings

    private var store: EventStore?
    private var reader: EventReader?
    private var summaryReader: EventReader?
    private let multicast = MulticastReceiver()
    private var apiContext: APIContext?
    private let apiServer = HTTPServer()

    private let queryQueue = DispatchQueue(label: "lo.stormcos.mcastsyslog.query", qos: .userInitiated)
    private let summaryQueue = DispatchQueue(label: "lo.stormcos.mcastsyslog.summary", qos: .utility)

    /// The hand-off between the receiver's delivery queue and the main thread.
    /// It lives outside the main-actor class on purpose: the delivery queue has
    /// to be able to append to it, and the receive thread is behind that.
    private let inbox = Inbox()

    private var queryGeneration = 0
    private var debounce: Task<Void, Never>?
    private var timers: [Timer] = []
    private var rateSamples: [(nanos: Int64, count: Int64)] = []
    private var cancellables = Set<AnyCancellable>()

    public init(settings: AppSettings) {
        self.settings = settings
        open()
        settings.$ordering
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Startup

    private func open() {
        let apiContext: APIContext
        do {
            let path = try EventStore.defaultPath()
            let store = try EventStore(path: path)
            self.store = store
            self.reader = try store.makeReader()
            self.summaryReader = try store.makeReader()
            apiContext = APIContext(store: store, receiver: multicast)
        } catch {
            storeError = "\(error)"
            state = .failed("\(error)")
            return
        }

        self.apiContext = apiContext
        apiContext.onStoreCleared = { [weak self] in
            // Cleared from the API: the window must not go on showing rows that
            // no longer exist behind it.
            Task { @MainActor in
                self?.events = []
                self?.unseen = 0
                self?.refreshSummaries()
                self?.refresh()
            }
        }
        apiServer.route = APIRouter(context: apiContext).route
        apiServer.onStateChange = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.apiRunning = self.apiServer.isRunning
                self.apiError = error
            }
        }
        publishSettingsToAPI()

        multicast.onBatch = { [weak self] batch in
            // On the receiver's delivery queue. Write first, then show — an
            // event that is on screen but not in the store would vanish on the
            // next query.
            guard let self else { return }
            do {
                try self.store?.insert(batch)
            } catch {
                Task { @MainActor in self.storeError = "\(error)" }
            }
            // Live subscribers see it only after it is stored, so the tail and
            // the history can never disagree about what happened.
            apiContext.live.publish(batch)
            self.enqueueForDisplay(batch)
        }
        multicast.onStatus = { [weak self] status in
            Task { @MainActor in self?.receiver = status }
        }

        startTimers()
        refreshSummaries()
        refresh()
        if settings.startListeningOnLaunch { startListening() }
        if settings.apiEnabled { startAPI() }
    }

    private func startTimers() {
        // The fleet, the store size and the filter menus. Two seconds is often
        // enough to feel live and rare enough to cost nothing.
        timers.append(Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSummaries()
                self?.publishSettingsToAPI()
            }
        })
        // Retention. Rarely has anything to do, and when it does it is one
        // range delete.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceRetention() }
        })
    }

    deinit {
        for timer in timers { timer.invalidate() }
    }

    // MARK: - The REST API

    public func startAPI() {
        publishSettingsToAPI()
        apiServer.start(settings.apiConfiguration)
    }

    public func stopAPI() {
        apiContext?.live.closeAll()
        apiServer.stop()
        apiRunning = false
    }

    public func restartAPI() {
        stopAPI()
        guard settings.apiEnabled else { return }
        startAPI()
    }

    /// The API runs on its own queue and must never read main-actor state from
    /// there, so what it is allowed to report is snapshotted to it instead.
    private func publishSettingsToAPI() {
        var snapshot = APIContext.Snapshot()
        snapshot.endpoint = settings.endpoint
        snapshot.retention = settings.retention
        snapshot.allowClearing = settings.apiAllowClearing
        snapshot.servesRemotely = settings.apiAllowRemote
        apiContext?.update(snapshot)
    }

    // MARK: - Listening

    public func startListening() {
        multicast.start(on: settings.endpoint)
    }

    public func stopListening() {
        multicast.stop()
    }

    public func toggleListening() {
        if receiver.isListening { stopListening() } else { startListening() }
    }

    // MARK: - Ingest

    /// Called on the delivery queue. Nothing here may block: the receive thread
    /// is behind this, and behind that is a node that must never wait.
    private nonisolated func enqueueForDisplay(_ batch: [LogEvent]) {
        let alreadyScheduled = inbox.append(batch)
        guard !alreadyScheduled else { return }
        // Coalesced: at most ten table updates a second however fast the wire is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in self?.flushPending() }
        }
    }

    private func flushPending() {
        let batch = inbox.drain()
        guard !batch.isEmpty else { return }

        sampleRate(batch.count)

        let ordering = settings.ordering
        let now = Timestamp.now()
        let matching = batch.filter { filter.matches($0, ordering: ordering, now: now) }
        guard !matching.isEmpty else { return }

        guard isFollowing, filter.range.isLive else {
            unseen += matching.count
            return
        }

        events.append(contentsOf: matching)
        // Sender-time ordering can put a late arrival before events already on
        // screen. Only the tail can be out of order, so only the tail is sorted.
        if settings.ordering == .senderTime {
            let tail = max(0, events.count - matching.count - 256)
            if tail < events.count {
                let head = Array(events[..<tail])
                let sorted = events[tail...].sorted { ($0.time(by: ordering), $0.id) < ($1.time(by: ordering), $1.id) }
                events = head + sorted
            }
        }
        trimToWindow()
    }

    private func trimToWindow() {
        let window = max(500, settings.liveWindow)
        if events.count > window {
            events.removeFirst(events.count - window)
        }
    }

    private func sampleRate(_ count: Int) {
        let now = Timestamp.now()
        rateSamples.append((now, Int64(count)))
        let horizon = now - 5_000_000_000
        rateSamples.removeAll { $0.nanos < horizon }
        let total = rateSamples.reduce(Int64(0)) { $0 + $1.count }
        guard let oldest = rateSamples.first else { eventsPerSecond = 0; return }
        let span = max(Double(now - oldest.nanos) / 1e9, 0.5)
        eventsPerSecond = Double(total) / span
    }

    // MARK: - Querying

    private func filterChanged(from old: FilterState) {
        guard filter != old else { return }
        if !filter.range.isLive { isFollowing = false }
        // Typing in the search box should not fire a query per keystroke,
        // least of all a substring scan.
        debounce?.cancel()
        let delay: UInt64 = filter.searchText == old.searchText ? 0 : 200_000_000
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Re-read the page from the store.
    public func refresh() {
        guard let reader else { return }
        queryGeneration += 1
        let generation = queryGeneration
        let query = filter.query(ordering: settings.ordering, limit: settings.liveWindow)
        let scanning = query.requiresScan
        state = scanning ? .scanning : .querying
        unseen = 0

        // Stop whatever is running before queueing this; a substring scan can
        // be seconds long and the user has already moved on.
        reader.cancel()
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let outcome = try reader.fetch(query)
                let counted = try reader.countMatching(query)
                Task { @MainActor in
                    self.apply(outcome, counted: counted, generation: generation)
                }
            } catch {
                Task { @MainActor in
                    guard generation == self.queryGeneration else { return }
                    self.state = .failed("\(error)")
                }
            }
        }
    }

    private func apply(_ outcome: QueryOutcome, counted: (count: Int64, exact: Bool), generation: Int) {
        guard generation == queryGeneration else { return }   // a newer query won
        if outcome.cancelled {
            state = .cancelled
            return
        }
        events = outcome.events
        matchCount = counted.count
        matchCountExact = counted.exact
        lastQueryNanos = outcome.elapsedNanos
        state = .idle
        trimToWindow()
    }

    /// Stop a running scan. The results already found are kept and labelled as
    /// partial rather than thrown away.
    public func cancelQuery() {
        reader?.cancel()
        state = .cancelled
    }

    private func catchUp() {
        guard filter.range.isLive else { return }
        unseen = 0
        refresh()
    }

    // MARK: - Jumping to a moment

    /// Land on a moment and show what surrounded it, on every node at once.
    public func jump(to nanos: Int64, window seconds: Double = 30) {
        guard let reader else { return }
        isFollowing = false
        let halfWindow = Int64(seconds * 1e9)
        var pinned = filter
        pinned.range = .window(from: nanos - halfWindow, to: nanos + halfWindow)
        // Deliberately not narrowed to the selected host: the whole point of a
        // moment is what every other node was saying at the same instant.
        pinned.hosts = []
        filter = pinned

        queryGeneration += 1
        let generation = queryGeneration
        let query = pinned.query(ordering: settings.ordering, limit: settings.liveWindow)
        state = .querying
        reader.cancel()
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                let outcome = try reader.around(nanos: nanos, window: halfWindow, query: query)
                let counted = (count: Int64(outcome.events.count), exact: !outcome.truncated)
                Task { @MainActor in
                    self.apply(outcome, counted: counted, generation: generation)
                    self.selection = Self.nearest(to: nanos, in: outcome.events, ordering: self.settings.ordering)?.id
                    self.showInspector = self.selection != nil
                }
            } catch {
                Task { @MainActor in self.state = .failed("\(error)") }
            }
        }
    }

    static func nearest(to nanos: Int64, in events: [LogEvent], ordering: TimeOrdering) -> LogEvent? {
        events.min { abs($0.time(by: ordering) - nanos) < abs($1.time(by: ordering) - nanos) }
    }

    /// Pin the view to the moment a given event happened, which is how you get
    /// from "this node failed" to "what was everything else saying".
    public func showMoment(of event: LogEvent) {
        jump(to: event.time(by: settings.ordering))
    }

    // MARK: - Summaries

    private func refreshSummaries() {
        guard let summaryReader, let store else { return }
        let ordering = settings.ordering
        let since = Timestamp.now() - 5 * 60 * 1_000_000_000   // the fleet, over five minutes
        summaryQueue.async {
            let nodes = (try? summaryReader.fleet(sinceNanos: since, ordering: ordering)) ?? []
            let hosts = (try? summaryReader.knownHosts()) ?? []
            let tags = (try? summaryReader.knownTags()) ?? []
            let stats = (try? store.stats()) ?? StoreStats()
            Task { @MainActor in
                self.fleet = nodes
                self.knownHosts = hosts
                self.knownTags = tags
                self.storeStats = stats
            }
        }
    }

    private func enforceRetention() {
        guard let store else { return }
        let policy = settings.retention
        summaryQueue.async {
            _ = try? store.enforce(policy)
        }
    }

    public func clearStore() {
        guard let store else { return }
        events = []
        unseen = 0
        summaryQueue.async {
            try? store.deleteAll()
            Task { @MainActor in
                self.refreshSummaries()
                self.refresh()
            }
        }
    }

    // MARK: - Convenience for the views

    public var selectedEvent: LogEvent? {
        guard let selection else { return nil }
        return events.first { $0.id == selection }
    }

    public func focus(host: String?) {
        var next = filter
        next.hosts = host.map { [$0] } ?? []
        filter = next
    }

    public var focusedHost: String? {
        filter.hosts.count == 1 ? filter.hosts.first : nil
    }

    /// The reader an export borrows. Its own connection, so a long export does
    /// not stall the table.
    public func makeExportReader() throws -> EventReader {
        guard let store else { throw ExportError.noStore }
        return try store.makeReader()
    }

    public func importEvents(_ imported: [LogEvent]) throws {
        guard let store else { throw ExportError.noStore }
        try store.insert(imported)
        refreshSummaries()
        refresh()
    }
}

/// A lock-protected buffer of events waiting to be shown.
///
/// `append` returns whether a flush was already scheduled, so exactly one is
/// scheduled per burst however many batches arrive in it.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LogEvent] = []
    private var flushScheduled = false

    func append(_ batch: [LogEvent]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        events.append(contentsOf: batch)
        let already = flushScheduled
        flushScheduled = true
        return already
    }

    func drain() -> [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        let batch = events
        events.removeAll(keepingCapacity: true)
        flushScheduled = false
        return batch
    }
}

public enum ExportError: LocalizedError {
    case noStore
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noStore: return "the event store is not open"
        case .cancelled: return "cancelled"
        }
    }
}
