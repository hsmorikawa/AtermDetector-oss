import Foundation
import SystemConfiguration

/// スキャン範囲の供給源 (テストで fake に差し替える)。
protocol NetworkInfoProviding: Sendable {
    func currentScanRange() -> ScanRange?
}

/// デフォルト経路インタフェースの IPv4/ネットマスクからスキャン範囲を導出する。
struct SystemNetworkInfo: NetworkInfoProviding {
    func currentScanRange() -> ScanRange? {
        guard let interfaceName = Self.primaryInterfaceName(),
              let config = Self.ipv4Configuration(of: interfaceName)
        else {
            return nil
        }
        return ScanRange.compute(interfaceName: interfaceName, localIP: config.ip, subnetMask: config.mask)
    }

    /// デフォルト経路 (State:/Network/Global/IPv4) の PrimaryInterface 名を返す。
    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "AtermDetector" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            return nil
        }
        return value["PrimaryInterface"] as? String
    }

    /// 指定インタフェースの IPv4 アドレスとネットマスクを getifaddrs で取得する。
    private static func ipv4Configuration(of interfaceName: String) -> (ip: String, mask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interfaceName,
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.pointee.ifa_netmask,
                  let ip = Self.ipv4String(of: addr),
                  let mask = Self.ipv4String(of: netmask)
            else {
                continue
            }
            return (ip, mask)
        }
        return nil
    }

    private static func ipv4String(of sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var sinAddr = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
