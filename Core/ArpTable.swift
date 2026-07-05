import Darwin
import Foundation

/// IP アドレス → MAC アドレスの解決 (テストで fake に差し替える)。
protocol MACResolving: Sendable {
    func macAddress(for ip: String) -> String?
}

/// システムの ARP テーブル (routing table の RTF_LLINFO エントリ) から MAC を引く。
/// プローブ応答直後は対象 IP のエントリが必ず存在するため、検出済み機器の MAC 取得に使える。
struct ArpTable: MACResolving {
    func macAddress(for ip: String) -> String? {
        guard let table = Self.fetchTable() else { return nil }
        return ArpParser.mac(for: ip, in: table)
    }

    /// sysctl (CTL_NET/PF_ROUTE/NET_RT_FLAGS/RTF_LLINFO) で ARP テーブルの生バイト列を取得する。
    private static func fetchTable() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(needed))
    }
}

/// ARP テーブル生バイト列の解析 (純関数、単体テスト対象)。
/// エントリ構造: rt_msghdr + sockaddr_in (対象 IP) + sockaddr_dl (リンク層アドレス)。
enum ArpParser {
    private static let sockaddrInSize = 16
    private static let macLength = 6

    static func mac(for ip: String, in table: [UInt8]) -> String? {
        guard let target = IPv4.octets(of: ip) else { return nil }
        let rtmSize = MemoryLayout<rt_msghdr>.size

        var offset = 0
        while offset + rtmSize <= table.count {
            // rt_msghdr 先頭の rtm_msglen (u_short, host endian = little)
            let msgLen = Int(table[offset]) | (Int(table[offset + 1]) << 8)
            guard msgLen > 0, offset + msgLen <= table.count else { return nil }
            defer { offset += msgLen }

            let sinStart = offset + rtmSize
            guard sinStart + 8 <= offset + msgLen,
                  table[sinStart + 1] == UInt8(AF_INET),
                  Array(table[(sinStart + 4) ..< (sinStart + 8)]) == target
            else {
                continue
            }

            // sockaddr は 4 byte 境界に丸めて連続配置される
            let sinLen = Int(table[sinStart])
            let sdlStart = sinStart + (sinLen == 0 ? 4 : (sinLen + 3) & ~3)
            guard sdlStart + 8 <= offset + msgLen else { continue }

            let nameLength = Int(table[sdlStart + 5]) // sdl_nlen
            let addressLength = Int(table[sdlStart + 6]) // sdl_alen
            let macStart = sdlStart + 8 + nameLength
            guard addressLength == macLength, macStart + macLength <= offset + msgLen else { continue }

            let mac = table[macStart ..< (macStart + macLength)]
            guard mac.contains(where: { $0 != 0 }) else { continue }
            return mac.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return nil
    }
}
