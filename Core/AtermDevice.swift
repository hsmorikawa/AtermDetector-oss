import Foundation

/// 検出された Aterm 1 台分の結果。
struct AtermDevice: Identifiable, Equatable {
    let name: String
    let modeName: String
    let ip: String
    /// ARP テーブルから解決した MAC アドレス (未解決は nil)。
    var macAddress: String?

    var id: String {
        ip
    }

    /// クイック設定 Web の URL。
    var setupURL: URL? {
        URL(string: "http://\(ip)")
    }

    /// 最終オクテット昇順ソート用キー。
    var lastOctet: Int {
        Int(ip.split(separator: ".").last ?? "") ?? 0
    }
}
