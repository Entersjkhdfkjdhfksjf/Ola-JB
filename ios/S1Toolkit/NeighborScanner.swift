import Darwin
import Foundation

/// Finds the scooter's link-local IPv6 address without a laptop.
///
/// iOS apps can't shell out to `ping`/`ip` the way the Android app does --
/// there's no process-exec API in the sandbox. Instead this sends a real
/// ICMPv6 Echo Request to the all-nodes multicast address (ff02::1) using
/// an unprivileged "ping socket" (`SOCK_DGRAM` + `IPPROTO_ICMPV6`), the
/// same technique Apple's own SimplePing sample code uses -- no special
/// entitlement required, no root. Every IPv6 host on the link answers,
/// and each reply's source address comes back directly from `recvfrom`,
/// so there's no separate neighbor-table lookup needed at all (iOS
/// doesn't expose one to apps anyway).
///
/// Deliberately does NOT assume "en0" is the right interface. That's only
/// the Wi-Fi interface when the iPhone is a *client* joining someone
/// else's network -- when it's hosting a Personal Hotspot instead, the
/// interface actually carrying traffic to/from connected devices is a
/// different one (commonly seen as "ap0" or a bridge interface,
/// depending on iOS version and hotspot mode). Rather than guess a name
/// that changes across configurations, this enumerates every live,
/// non-loopback interface that currently has a link-local IPv6 address
/// and scans all of them.
enum NeighborScanner {

    struct Candidate {
        let address: String   // includes the %zone suffix, ready to hand to ScooterClient
        let iface: String
    }

    private static func candidateInterfaces() -> [String] {
        var names: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        let upFlag = UInt32(bitPattern: Int32(IFF_UP))
        let loopbackFlag = UInt32(bitPattern: Int32(IFF_LOOPBACK))

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }

            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let flags = p.pointee.ifa_flags
            guard flags & upFlag != 0, flags & loopbackFlag == 0 else { continue }

            let name = String(cString: p.pointee.ifa_name)
            if name == "lo0" || names.contains(name) { continue }

            let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            var addrCopy = sin6.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(INET6_ADDRSTRLEN))
            if String(cString: buf).hasPrefix("fe80:") {
                names.append(name)
            }
        }
        return names
    }

    static func findCandidates(timeout: TimeInterval = 2.0) -> [Candidate] {
        var all: [Candidate] = []
        for iface in candidateInterfaces() {
            all.append(contentsOf: scan(iface: iface, timeout: timeout))
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.address).inserted }
    }

    private static func scan(iface: String, timeout: TimeInterval) -> [Candidate] {
        let ifIndex = if_nametoindex(iface)
        guard ifIndex != 0 else { return [] }

        let sock = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard sock >= 0 else { return [] }
        defer { close(sock) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Destination: ff02::1 (all-nodes multicast), scoped to this interface.
        var dest = sockaddr_in6()
        dest.sin6_family = sa_family_t(AF_INET6)
        dest.sin6_port = 0
        dest.sin6_scope_id = ifIndex
        withUnsafeMutableBytes(of: &dest.sin6_addr) { raw in
            raw.storeBytes(of: UInt8(0xff), toByteOffset: 0, as: UInt8.self)
            raw.storeBytes(of: UInt8(0x02), toByteOffset: 1, as: UInt8.self)
            raw.storeBytes(of: UInt8(0x01), toByteOffset: 15, as: UInt8.self)
        }

        // Minimal ICMPv6 Echo Request: type=128, code=0, checksum=0 (the
        // kernel fills in the checksum for SOCK_DGRAM ICMP sockets),
        // identifier/sequence, no payload needed.
        var packet: [UInt8] = [128, 0, 0, 0, 0x12, 0x34, 0, 1]
        let sent = packet.withUnsafeMutableBytes { buf -> Int in
            withUnsafePointer(to: &dest) { destPtr -> Int in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(sock, buf.baseAddress, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent > 0 else { return [] }

        var found: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 512)

        while Date() < deadline {
            var from = sockaddr_in6()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let n = withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(sock, &buffer, buffer.count, 0, sockPtr, &fromLen)
                }
            }
            if n <= 0 { break } // timeout or error -- stop waiting for more replies

            var addrBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            withUnsafePointer(to: &from.sin6_addr) { addrPtr in
                _ = inet_ntop(AF_INET6, addrPtr, &addrBuf, socklen_t(INET6_ADDRSTRLEN))
            }
            let addr = String(cString: addrBuf)
            if addr.hasPrefix("fe80:"), !found.contains(addr) {
                found.append(addr)
            }
        }

        return found.map { Candidate(address: "\($0)%\(iface)", iface: iface) }
    }
}
