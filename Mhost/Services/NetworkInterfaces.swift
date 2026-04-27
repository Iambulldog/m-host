import Darwin
import Foundation
import SystemConfiguration

/// ตัวแทน interface เครือข่ายหนึ่งตัวที่ active อยู่ (มี IP)
struct NetworkInterface: Identifiable, Hashable {
    var id: String { "\(name)-\(ip)" }
    let name: String          // BSD name เช่น "en0"
    let displayName: String   // ชื่อ user-friendly เช่น "Wi-Fi"
    let ip: String            // IP address ตัวเลข
    let isIPv6: Bool
}

/// อ่านรายการ network interface ที่ active + มี IPv4/IPv6
/// เน้น IPv4 ก่อน (เรียงไว้บนสุด) เพราะใช้กับ LAN proxy ส่วนใหญ่
enum NetworkInterfaceProvider {

    /// คืน interfaces ที่ up + ไม่ใช่ loopback + ไม่ใช่ link-local IPv6
    /// `includeIPv6 = false` (default) → กรองเอาเฉพาะ IPv4 มาแสดงให้สั้น
    static func current(includeIPv6: Bool = false) -> [NetworkInterface] {
        var results: [NetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        // map BSD name → friendly name (Wi-Fi, Ethernet, ฯลฯ) ผ่าน SystemConfiguration
        let displayNames = friendlyInterfaceNames()

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            let upRunning = Int32(IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & Int32(IFF_LOOPBACK)) != 0
            guard (flags & upRunning) == upRunning, !isLoopback else { continue }
            guard let saPtr = p.pointee.ifa_addr else { continue }
            let family = saPtr.pointee.sa_family

            let isV4 = (family == UInt8(AF_INET))
            let isV6 = (family == UInt8(AF_INET6))
            guard isV4 || (includeIPv6 && isV6) else { continue }

            let saLen: socklen_t = isV4
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(saPtr, saLen, &host, socklen_t(NI_MAXHOST),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }

            let ip = String(cString: host)
            // กรอง link-local IPv6 (fe80::...%enX) — เป็นเสียงรบกวน
            if isV6 && ip.lowercased().hasPrefix("fe80") { continue }

            let bsdName = String(cString: p.pointee.ifa_name)
            let friendly = displayNames[bsdName] ?? bsdName

            results.append(NetworkInterface(
                name: bsdName,
                displayName: friendly,
                ip: ip,
                isIPv6: isV6
            ))
        }

        // เรียง: IPv4 ก่อน, แล้วตามชื่อ
        results.sort { (a, b) in
            if a.isIPv6 != b.isIPv6 { return !a.isIPv6 }
            return a.name < b.name
        }
        return results
    }

    /// อ่าน BSD name → friendly name จาก SystemConfiguration
    /// (เช่น en0 → "Wi-Fi", en1 → "Ethernet")
    private static func friendlyInterfaceNames() -> [String: String] {
        var map: [String: String] = [:]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return map
        }
        for iface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            map[bsd] = name
        }
        return map
    }
}
