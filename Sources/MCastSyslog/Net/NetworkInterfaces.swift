import Foundation
import Darwin

/// One IPv4-capable interface, as the receiver needs to see it: a name and the
/// address to hand to `IP_ADD_MEMBERSHIP` as the membership's local end.
public struct NetworkInterface: Hashable, Sendable, Identifiable {
    public let name: String
    /// The interface's IPv4 address, in network byte order.
    public let addressRaw: UInt32
    public let address: String
    public let isLoopback: Bool

    public var id: String { "\(name)/\(address)" }
}

public enum NetworkInterfaces {

    /// Every interface that can carry a multicast membership right now.
    ///
    /// Loopback is included deliberately: the node sets loopback delivery on, so
    /// a viewer running on a node — or beside a `stormsim` on this Mac — sees
    /// the stream on `lo0` and nowhere else.
    public static func multicastCapableIPv4() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [NetworkInterface] = []
        var seen = Set<String>()

        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_MULTICAST != 0 else { continue }

            let addressRaw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            // 0.0.0.0 on an interface is an address that has not been configured yet.
            guard addressRaw != 0 else { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            let iface = NetworkInterface(
                name: name,
                addressRaw: addressRaw,
                address: ipv4String(addressRaw),
                isLoopback: flags & IFF_LOOPBACK != 0
            )
            // An interface with several addresses only needs one membership.
            if seen.insert(name).inserted { found.append(iface) }
        }
        return found.sorted { ($0.isLoopback ? 1 : 0, $0.name) < ($1.isLoopback ? 1 : 0, $1.name) }
    }

    public static func ipv4String(_ raw: UInt32) -> String {
        var addr = in_addr(s_addr: raw)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "0.0.0.0" }
        return String(cString: buf)
    }

    /// Network byte order, or nil if `s` is not a dotted quad.
    public static func parseIPv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return addr.s_addr
    }

    /// 224.0.0.0/4.
    public static func isMulticast(_ raw: UInt32) -> Bool {
        (UInt32(bigEndian: raw) >> 28) == 0b1110
    }
}
