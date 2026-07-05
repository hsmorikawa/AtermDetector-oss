import Foundation

/// IPv4 アドレス文字列の解析と検証。
enum IPv4 {
    /// "a.b.c.d" を 4 オクテットに分解する。形式不正は nil。
    static func octets(of address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            result.append(value)
        }
        return result
    }

    static func isValid(_ address: String) -> Bool {
        octets(of: address) != nil
    }
}
