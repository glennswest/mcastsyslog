import Foundation
import Darwin
import Network

/// Where to listen. The default is the administratively scoped group the node
/// emits to; a node overridden with `stormpump.syslog=<host:port>` to a unicast
/// address works identically, and so does this — it just binds and never joins.
public struct ListenEndpoint: Equatable, Codable, Sendable {
    public var address: String
    public var port: UInt16

    public static let `default` = ListenEndpoint(address: "239.255.42.1", port: 5514)

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    public var isMulticast: Bool {
        guard let raw = NetworkInterfaces.parseIPv4(address) else { return false }
        return NetworkInterfaces.isMulticast(raw)
    }

    public var description: String { "\(address):\(port)" }
}

/// What the receiver is doing, for the status bar.
public struct ReceiverStatus: Equatable, Sendable {
    public var isListening = false
    public var endpoint = ListenEndpoint.default
    public var joined: [NetworkInterface] = []
    public var datagrams: Int64 = 0
    public var bytes: Int64 = 0
    public var malformed: Int64 = 0
    /// Batches handed off but not yet written. A number that stays high means
    /// the store is the bottleneck, not the wire.
    public var backlog: Int = 0
    public var lastError: String?
    public var lastReceiveNanos: Int64?
}

/// Joins the group and reads it.
///
/// The one hard rule: this socket never transmits. There is no `sendto` in this
/// file and there must never be one. A viewer that can ask a node for anything
/// is a viewer that can slow a node down, which is the failure the whole
/// multicast path exists to avoid.
public final class MulticastReceiver: @unchecked Sendable {

    /// Handed a batch of parsed events on a background queue. Never called on
    /// the main thread, and never called from the receive thread itself.
    public var onBatch: (([LogEvent]) -> Void)?
    /// Status changes, for the UI. Also off the main thread.
    public var onStatus: ((ReceiverStatus) -> Void)?

    private let lock = NSLock()
    private var status = ReceiverStatus()
    private var fd: Int32 = -1
    private var thread: Thread?
    private var stopping = false
    private var memberships: [NetworkInterface] = []
    private var endpoint = ListenEndpoint.default

    private let deliveryQueue = DispatchQueue(label: "lo.stormcos.mcastsyslog.delivery", qos: .utility)
    /// A ceiling on batches in flight. When the store falls behind, the receive
    /// thread waits here and the kernel's receive buffer absorbs the difference
    /// — and then drops, visibly, which is honest. The alternative is an
    /// unbounded queue that turns a slow disk into a memory leak.
    private let backlogSlots = DispatchSemaphore(value: 64)
    private var pathMonitor: NWPathMonitor?

    private var pending: [LogEvent] = []
    private var pendingSinceNanos: Int64 = 0

    /// Flush on either bound, whichever comes first: enough events that a
    /// transaction is worth it, or long enough that a quiet fleet still appears
    /// live.
    private static let batchSize = 512
    private static let batchIntervalNanos: Int64 = 50_000_000   // 50ms
    private static let recvTimeoutMillis: Int32 = 200

    public init() {}

    deinit { stop() }

    public var currentStatus: ReceiverStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    // MARK: - Lifecycle

    public func start(on endpoint: ListenEndpoint) {
        stop()
        lock.lock()
        self.endpoint = endpoint
        stopping = false
        status = ReceiverStatus(isListening: false, endpoint: endpoint)
        lock.unlock()

        do {
            let socket = try openSocket(endpoint)
            lock.lock()
            fd = socket
            status.isListening = true
            lock.unlock()
        } catch {
            lock.lock()
            status.lastError = "\(error)"
            lock.unlock()
            publishStatus()
            return
        }

        refreshMemberships()
        startPathMonitor()

        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "mcastsyslog.receive"
        // Above default so a burst is drained promptly, below the UI so it can
        // never make the app feel slow.
        t.qualityOfService = .userInitiated
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        publishStatus()
    }

    public func stop() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let socket = fd
        fd = -1
        lock.unlock()

        pathMonitor?.cancel()
        pathMonitor = nil

        if socket >= 0 {
            // The loop wakes within the receive timeout and sees `stopping`.
            shutdown(socket, SHUT_RD)
            close(socket)
        }
        thread = nil

        lock.lock()
        status.isListening = false
        status.joined = []
        memberships = []
        lock.unlock()
        publishStatus()
    }

    public func restart() {
        let e = currentStatus.endpoint
        start(on: e)
    }

    // MARK: - Socket

    private enum ReceiverError: LocalizedError {
        case socketFailed(String)
        case bindFailed(String)
        case badAddress(String)

        var errorDescription: String? {
            switch self {
            case .socketFailed(let s): return "could not open the socket: \(s)"
            case .bindFailed(let s): return "could not bind: \(s)"
            case .badAddress(let s): return "not an IPv4 address: \(s)"
            }
        }
    }

    private func openSocket(_ endpoint: ListenEndpoint) throws -> Int32 {
        guard NetworkInterfaces.parseIPv4(endpoint.address) != nil else {
            throw ReceiverError.badAddress(endpoint.address)
        }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw ReceiverError.socketFailed(errnoText()) }

        var yes: Int32 = 1
        // Both, so several viewers — and a `stormsim` — can hold the port at once.
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // A generous kernel buffer is what absorbs a node replaying a boot's
        // backlog. Ask high, settle for whatever the kernel grants.
        for size in [8 << 20, 4 << 20, 2 << 20, 1 << 20] {
            var v = Int32(size)
            if setsockopt(s, SOL_SOCKET, SO_RCVBUF, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
        }

        var timeout = timeval(tv_sec: 0, tv_usec: Int32(Self.recvTimeoutMillis) * 1000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Bind to the wildcard even for a multicast group: binding to the group
        // address itself works on Darwin but not everywhere, and the wildcard
        // also lets a unicast override land on the same socket.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let text = errnoText()
            close(s)
            throw ReceiverError.bindFailed(text)
        }
        return s
    }

    // MARK: - Memberships

    /// Join the group on every IPv4 interface, and drop memberships for
    /// interfaces that have gone away. Called at start, on every path change,
    /// and periodically from the receive loop — waking from sleep does not
    /// always produce a path event, and a membership silently lost to a sleep
    /// is a viewer that has gone quiet without saying so.
    private func refreshMemberships() {
        lock.lock()
        let socket = fd
        let endpoint = self.endpoint
        let current = memberships
        lock.unlock()

        guard socket >= 0, endpoint.isMulticast,
              let group = NetworkInterfaces.parseIPv4(endpoint.address) else {
            if socket >= 0, !endpoint.isMulticast {
                // Unicast override: nothing to join, the bind is enough.
                lock.lock(); memberships = []; status.joined = []; lock.unlock()
                publishStatus()
            }
            return
        }

        let live = NetworkInterfaces.multicastCapableIPv4()
        let liveSet = Set(live)
        let currentSet = Set(current)
        guard liveSet != currentSet else { return }

        for gone in currentSet.subtracting(liveSet) {
            var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: group),
                               imr_interface: in_addr(s_addr: gone.addressRaw))
            setsockopt(socket, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        }

        var joined: [NetworkInterface] = []
        for iface in live {
            var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: group),
                               imr_interface: in_addr(s_addr: iface.addressRaw))
            let rc = setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
            // EADDRINUSE means this membership already exists, which is success.
            if rc == 0 || errno == EADDRINUSE { joined.append(iface) }
        }

        lock.lock()
        memberships = joined
        status.joined = joined
        if joined.isEmpty {
            status.lastError = "no interface accepted a membership for \(endpoint.address)"
        } else if status.lastError?.hasPrefix("no interface") == true {
            status.lastError = nil
        }
        lock.unlock()
        publishStatus()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // The path is already changing when this fires; the addresses
            // usually settle a moment later.
            self?.deliveryQueue.asyncAfter(deadline: .now() + 0.5) { self?.refreshMemberships() }
        }
        monitor.start(queue: deliveryQueue)
        pathMonitor = monitor
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        // 64 KiB: the largest a UDP datagram can be. The node truncates at 8 KiB,
        // but a buffer that could truncate is a buffer that loses evidence.
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var lastMembershipCheck = Timestamp.now()
        var datagrams: Int64 = 0
        var bytes: Int64 = 0
        var malformed: Int64 = 0
        var lastStatusPublish = Timestamp.now()

        while true {
            lock.lock()
            let socket = fd
            let done = stopping
            lock.unlock()
            guard !done, socket >= 0 else { break }

            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, buffer, capacity, 0, $0, &fromLen)
                }
            }

            let now = Timestamp.now()

            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                let event = SyslogParser.parse(data, from: Self.peerString(from), receivedAt: now)
                datagrams += 1
                bytes += Int64(n)
                if event.flags.contains(.malformed) { malformed += 1 }

                pending.append(event)
                if pendingSinceNanos == 0 { pendingSinceNanos = now }
            } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                lock.lock()
                if !stopping { status.lastError = "receive failed: \(errnoText())" }
                lock.unlock()
                publishStatus()
                break
            }

            let due = pending.count >= Self.batchSize
                || (pendingSinceNanos != 0 && now - pendingSinceNanos >= Self.batchIntervalNanos)
            if due, !pending.isEmpty {
                flush()
            }

            // Every two seconds, whether or not anything arrived.
            if now - lastMembershipCheck > 2_000_000_000 {
                lastMembershipCheck = now
                refreshMemberships()
            }

            if now - lastStatusPublish > 250_000_000 {
                lastStatusPublish = now
                lock.lock()
                status.datagrams = datagrams
                status.bytes = bytes
                status.malformed = malformed
                if datagrams > 0 { status.lastReceiveNanos = now }
                lock.unlock()
                publishStatus()
            }
        }

        if !pending.isEmpty { flush() }
    }

    private func flush() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingSinceNanos = 0

        // Blocks the receive thread only when the store is 64 batches behind.
        backlogSlots.wait()
        lock.lock(); status.backlog += 1; lock.unlock()

        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.onBatch?(batch)
            self.lock.lock(); self.status.backlog -= 1; self.lock.unlock()
            self.backlogSlots.signal()
        }
    }

    private func publishStatus() {
        let snapshot = currentStatus
        deliveryQueue.async { [weak self] in self?.onStatus?(snapshot) }
    }

    // MARK: - Helpers

    private static func peerString(_ storage: sockaddr_storage) -> String {
        var s = storage
        return withUnsafePointer(to: &s) { ptr in
            ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                NetworkInterfaces.ipv4String($0.pointee.sin_addr.s_addr)
            }
        }
    }
}

func errnoText() -> String {
    String(cString: strerror(errno))
}
