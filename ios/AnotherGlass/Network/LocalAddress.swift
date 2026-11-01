import Darwin
import Foundation

struct LocalAddress: Identifiable, Hashable {
    let interface: String
    let address: String
    var id: String { "\(interface):\(address)" }
    var label: String { interface == "en0" ? "Wi-Fi" : "\(interface) / hotspot" }

    static func all() -> [LocalAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var results: [LocalAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard let socket = item.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            results.append(LocalAddress(interface: name, address: String(cString: host)))
        }
        return results.sorted { lhs, rhs in
            if lhs.interface == "en0", rhs.interface != "en0" { return true }
            if rhs.interface == "en0", lhs.interface != "en0" { return false }
            return lhs.id < rhs.id
        }
    }

    static func isIPv4(_ string: String) -> Bool {
        var parsed = in_addr()
        return string.withCString { inet_pton(AF_INET, $0, &parsed) } == 1
    }
}
