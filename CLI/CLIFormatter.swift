import Foundation

/// 検出結果のテキスト整形。
enum CLIFormatter {
    static let notFoundHint = """
    Atermが見つかりませんでした。
    ヒント: macOS 15以降では「システム設定 > プライバシーとセキュリティ > ローカルネットワーク」で
    ターミナルを許可し、再実行してください。
    """

    /// clean=true は tab 区切り・ヘッダなしの機械可読出力、false は整形テーブル。
    static func render(devices: [AtermDevice], clean: Bool) -> String {
        clean ? renderClean(devices) : renderTable(devices)
    }

    private static func mac(_ device: AtermDevice) -> String {
        device.macAddress ?? "-"
    }

    private static func url(_ device: AtermDevice) -> String {
        device.setupURL?.absoluteString ?? "http://\(device.ip)"
    }

    private static func renderClean(_ devices: [AtermDevice]) -> String {
        devices
            .map { [$0.ip, $0.name, $0.modeName, mac($0), url($0)].joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private static func renderTable(_ devices: [AtermDevice]) -> String {
        guard !devices.isEmpty else { return notFoundHint }

        let header = ["機種名", "動作モード", "MACアドレス", "IPアドレス", "クイック設定Web"]
        var rows = [header]
        rows += devices.map { [$0.name, $0.modeName, mac($0), $0.ip, url($0)] }

        // 列ごとの表示幅 (全角=2) を求めて左詰めパディング
        let columnCount = header.count
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], displayWidth(cell))
            }
        }

        var lines = rows.map { row in
            row.enumerated()
                .map { column, cell in pad(cell, to: widths[column]) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        let separator = String(repeating: "-", count: widths.reduce(0, +) + (columnCount - 1) * 2)
        lines.insert(separator, at: 1)
        lines.append("")
        lines.append("検索完了 (\(devices.count) 台検出)")
        return lines.joined(separator: "\n")
    }

    /// 全角文字を幅 2、半角を幅 1 として数える。
    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { width, character in
            width + (character.isFullWidth ? 2 : 1)
        }
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }
}

private extension Character {
    /// 概算の東アジア全角判定 (表示幅計算用)。
    var isFullWidth: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100 ... 0x115F, // Hangul Jamo
                 0x2E80 ... 0x303E, // CJK 部首・記号
                 0x3041 ... 0x33FF, // かな・CJK 記号
                 0x3400 ... 0x4DBF, // CJK 拡張 A
                 0x4E00 ... 0x9FFF, // CJK 統合漢字
                 0xF900 ... 0xFAFF, // CJK 互換漢字
                 0xFF00 ... 0xFF60, // 全角 ASCII
                 0xFFE0 ... 0xFFE6: // 全角記号
                true
            default:
                false
            }
        }
    }
}
