import Foundation

/// Aterm の動作モード番号 → 名称の対応表。
enum SysMode {
    static let names = [
        "ブリッジ",
        "PPPoEルータ",
        "ローカルルータ",
        "無線LAN子機",
        "無線LAN中継機",
        "MAP-E",
        "464XLAT",
        "DS-Lite",
        "固定IP1",
        "複数固定IP",
        "メッシュ中継機",
    ]

    /// 範囲外・取得失敗時の表示。
    static let unknown = "-"

    static func name(for index: Int?) -> String {
        guard let index, names.indices.contains(index) else { return unknown }
        return names[index]
    }
}
