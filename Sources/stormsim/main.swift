// stormsim — synthetic stormcos nodes, for working on the viewer without a
// fleet to watch.
//
// It emits exactly what a node emits: RFC 5424 to the multicast group, TTL 4,
// loopback on, one line per datagram, never retrying and never blocking. It
// also emits the two notices a node makes about its own volume, the occasional
// nil timestamp from a node whose clock is not set, and the occasional
// malformed frame — because those are the paths in the viewer most worth being
// able to look at.

import Foundation
import Darwin

struct Options {
    var group = "239.255.42.1"
    var port: UInt16 = 5514
    var nodes = 4
    var rate = 12.0          // lines per second, across all nodes
    var duration: Double = 0 // 0 means until interrupted
    var ttl: Int32 = 4
    var seed: UInt64 = 0x5EED_5701
}

func parseArguments() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let v = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return v
    }

    if arguments.contains("-h") || arguments.contains("--help") {
        print("""
        stormsim — synthetic stormcos nodes emitting RFC 5424 to a multicast group

          --group <addr>     multicast group or unicast host (default 239.255.42.1)
          --port <n>         port (default 5514)
          --nodes <n>        how many nodes to pretend to be (default 4)
          --rate <n>         lines per second across all nodes (default 12)
          --duration <secs>  stop after this long (default: until interrupted)
          --ttl <n>          multicast TTL (default 4)

        Loopback delivery is on, so a viewer on this Mac sees the stream.
        """)
        exit(0)
    }

    if let v = value(after: "--group") { options.group = v }
    if let v = value(after: "--port"), let n = UInt16(v) { options.port = n }
    if let v = value(after: "--nodes"), let n = Int(v) { options.nodes = max(1, n) }
    if let v = value(after: "--rate"), let n = Double(v) { options.rate = max(0.1, n) }
    if let v = value(after: "--duration"), let n = Double(v) { options.duration = n }
    if let v = value(after: "--ttl"), let n = Int32(v) { options.ttl = n }
    return options
}

/// Deterministic, so a run is reproducible when something in the viewer looks
/// wrong and needs looking at twice.
struct Random {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0..<items.count)] }
}

let options = parseArguments()

// MARK: - Socket

let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("stormsim: socket: \(String(cString: strerror(errno)))\n".utf8))
    exit(1)
}

var ttl = options.ttl
setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
// Loopback on, so a watcher on this machine sees the stream — the same reason
// a node sets it.
var loop: Int32 = 1
setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<Int32>.size))

var destination = sockaddr_in()
destination.sin_family = sa_family_t(AF_INET)
destination.sin_port = options.port.bigEndian
destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
guard inet_pton(AF_INET, options.group, &destination.sin_addr) == 1 else {
    FileHandle.standardError.write(Data("stormsim: \(options.group) is not an IPv4 address\n".utf8))
    exit(1)
}

func send(_ frame: String) {
    let bytes = Array(frame.utf8)
    _ = withUnsafePointer(to: &destination) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bytes.withUnsafeBufferPointer { buffer in
                // Never retries, never blocks. A datagram nobody takes is not
                // the node's problem.
                sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - What a node says

let tags = ["stormpump", "stormblock", "registry", "kernel", "ublk", "netd"]

let ordinary = [
    "volume %VOL% attached, 4 ublk queues, depth 128",
    "peer %HOST% joined the ring, epoch %N%",
    "checkpoint written in %N%ms, %N% pages",
    "registry: pulled %VOL%:latest, %N% layers cached",
    "reconciled %N% volumes, %N% changed",
    "DEBUG scrub pass %N% complete, no differences",
    "TRACE ublk queue %N% depth %N%, inflight %N%",
    "lease renewed, ttl 30s",
    "GC reclaimed %N% MiB from %N% dead snapshots",
]

let unhappy = [
    "WARN volume %VOL% degraded: %N% of 3 replicas online",
    "WARN slow commit: %N%ms, threshold 250ms",
    "ERROR ublk queue %N% reset after io timeout",
    "ERROR failed to open %VOL%: no such device or address",
    "ERROR registry: pull %VOL%:latest failed after %N% attempts",
    "FATAL storage engine stopped serving: quorum lost",
]

var random = Random(seed: options.seed)
let hosts = (0..<options.nodes).map { "storm-\(String(format: "%02d", $0 + 1))" }
// One node in the fleet has no clock, which is the case the viewer has to
// render honestly rather than inventing a plausible time for.
let clocklessHost = options.nodes > 2 ? hosts[options.nodes - 1] : nil

func fill(_ template: String, _ random: inout Random) -> String {
    var text = template
    while let range = text.range(of: "%N%") {
        text.replaceSubrange(range, with: String(random.int(1..<9999)))
    }
    while let range = text.range(of: "%VOL%") {
        text.replaceSubrange(range, with: "vol-\(random.int(100..<999))")
    }
    while let range = text.range(of: "%HOST%") {
        text.replaceSubrange(range, with: random.pick(hosts))
    }
    return text
}

func severity(for message: String) -> Int {
    if message.hasPrefix("ERROR") || message.hasPrefix("FATAL") { return 3 }
    if message.hasPrefix("WARN") { return 4 }
    if message.hasPrefix("DEBUG") || message.hasPrefix("TRACE") { return 7 }
    return 6
}

func frame(host: String, tag: String, severity: Int, message: String, clockUnset: Bool) -> String {
    let pri = 16 * 8 + severity
    let timestamp = clockUnset ? "-" : Timestamp.format(Timestamp.now(), style: .rfc3339UTC)
    return "<\(pri)>1 \(timestamp) \(host) \(tag) - - - \(message)"
}

// MARK: - Run

print("stormsim: \(options.nodes) nodes → \(options.group):\(options.port) at \(options.rate)/s, TTL \(options.ttl)")
if let clocklessHost { print("stormsim: \(clocklessHost) has no clock and will send the nil timestamp") }
print("stormsim: ^C to stop")

let started = Date()
let interval = 1.0 / options.rate
var emitted = 0

signal(SIGINT) { _ in
    print("\nstormsim: stopped")
    exit(0)
}

while options.duration == 0 || Date().timeIntervalSince(started) < options.duration {
    let host = random.pick(hosts)
    let tag = random.pick(tags)
    let clockUnset = host == clocklessHost
    let roll = random.double()

    if roll < 0.03 {
        // The node collapsed a run of identical lines.
        send(frame(host: host, tag: tag, severity: 5,
                   message: "last message repeated \(random.int(2..<40)) times",
                   clockUnset: clockUnset))
    } else if roll < 0.05 {
        // The node's token bucket ran dry, and it says what it held back.
        send(frame(host: host, tag: tag, severity: 4,
                   message: "\(random.int(20..<900)) messages dropped — over 200 lines/s",
                   clockUnset: clockUnset))
    } else if roll < 0.065 {
        // Something that is not RFC 5424 at all. The viewer must keep it.
        send("garbled\u{0}frame from \(host) — \(random.int(0..<99999))")
    } else if roll < 0.20 {
        let message = fill(random.pick(unhappy), &random)
        send(frame(host: host, tag: tag, severity: severity(for: message),
                   message: message, clockUnset: clockUnset))
    } else {
        let message = fill(random.pick(ordinary), &random)
        send(frame(host: host, tag: tag, severity: severity(for: message),
                   message: message, clockUnset: clockUnset))
    }

    emitted += 1
    if emitted % 500 == 0 { print("stormsim: \(emitted) sent") }
    Thread.sleep(forTimeInterval: interval)
}

print("stormsim: \(emitted) sent")
