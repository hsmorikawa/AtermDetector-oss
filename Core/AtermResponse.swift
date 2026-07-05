import Foundation

/// 機器情報照会 (getparamcmd_no_auth) の応答パース。
/// 契約: specs/001-macos-aterm-app/contracts/aterm-probe-protocol.md
enum AtermResponse {
    private static let productNamePrefix = "PRODUCT_NAME="

    /// 応答 body から CR/LF を除去する。
    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// PRODUCT_NAME_GET 応答から機種名を取り出す。
    /// `PRODUCT_NAME=` で始まり値が空でない場合のみ機種名を返す (それ以外は Aterm ではない)。
    static func productName(from raw: String) -> String? {
        let body = normalize(raw)
        guard body.hasPrefix(productNamePrefix) else { return nil }
        let name = String(body.dropFirst(productNamePrefix.count))
        return name.isEmpty ? nil : name
    }

    /// SYS_MODE_GET 応答から動作モード番号を取り出す。
    /// 最初の `=` 以降を整数として解釈し、整数でなければ nil (範囲判定は SysMode の責務)。
    static func sysModeIndex(from raw: String) -> Int? {
        let body = normalize(raw)
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let value = String(body[body.index(after: equals)...])
        return Int(value)
    }
}
