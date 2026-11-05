import Foundation

/// Whether the Mac has a network interface ShellyLanMan's mDNS browser can use:
/// up, multicast-capable, with an IPv4 address, not loopback and not a container
/// bridge. Mirrors the interface selection in the server (internal/discovery).
enum NetworkProbe {
    private static let virtualPrefixes = ["docker", "br-", "veth", "virbr", "cni", "flannel", "podman", "vnet"]

    static func hasUsableInterface() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = node {
            defer { node = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0,
                  let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if virtualPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            return true
        }
        return false
    }
}
