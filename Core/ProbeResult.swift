import Foundation

/// 単一 IP デバッグ検索の結果 (生応答含む)。
struct ProbeResult: Equatable {
    let ip: String
    /// 機種名照会の生応答 (nil = 応答なし)。
    let productNameRaw: String?
    /// 動作モード照会の生応答 (nil = 応答なし / 未実行)。
    let sysModeRaw: String?
    /// Aterm と判定された場合の解釈結果。
    let device: AtermDevice?
}
