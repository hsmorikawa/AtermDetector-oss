import Foundation

/// 自ホストの IPv4 とサブネットマスクから導出したスキャン範囲 (/24 近似)。
struct ScanRange: Equatable {
    let interfaceName: String
    let localIP: String
    let subnetMask: String
    let targets: [String]
    /// 第 3 オクテットが 255 でないマスクを 254 アドレスに丸めたとき true (注意表示用)。
    let isTruncated: Bool

    static let maxHosts = 254

    /// 導出規則 (data-model.md):
    /// net4 = ip4 & mask4。mask3 == 255 なら max = 254 - mask4、それ以外は max = 254 (truncated)。
    /// 対象は base.(net4+1) ... base.(net4+max)。
    static func compute(interfaceName: String, localIP: String, subnetMask: String) -> ScanRange? {
        guard let ip = IPv4.octets(of: localIP), let mask = IPv4.octets(of: subnetMask) else {
            return nil
        }
        let net4 = Int(ip[3] & mask[3])
        let hostCount: Int
        let isTruncated: Bool
        if mask[2] == 255 {
            hostCount = maxHosts - Int(mask[3])
            isTruncated = false
        } else {
            hostCount = maxHosts
            isTruncated = true
        }
        let base = "\(ip[0]).\(ip[1]).\(ip[2])"
        let targets = hostCount > 0 ? (1 ... hostCount).map { "\(base).\(net4 + $0)" } : []
        return ScanRange(
            interfaceName: interfaceName,
            localIP: localIP,
            subnetMask: subnetMask,
            targets: targets,
            isTruncated: isTruncated
        )
    }
}
