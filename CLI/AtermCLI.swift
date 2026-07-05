import Foundation

/// ローカルネットワーク上の Aterm を検出するコマンドライン版。
@main
struct AtermCLI {
    static let usage = """
    aterm-cli — ローカルネットワーク上の Aterm を検出する

    使い方:
      aterm-cli                サブネット全体をスキャンして一覧表示
      aterm-cli --clean        タブ区切り・ヘッダなしで出力 (パイプ/スクリプト向け)
      aterm-cli --ip <IP>      指定 IP のみをプローブ (デバッグ用)
      aterm-cli --help         このヘルプを表示

    出力列:
      既定 (整形表示):  機種名 / 動作モード / MACアドレス / IPアドレス / クイック設定Web
      --clean (タブ区切り): IPアドレス<TAB>機種名<TAB>動作モード<TAB>MACアドレス<TAB>クイック設定Web
    """

    static func main() async {
        let options: CLIOptions
        do {
            options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data((message(for: error) + "\n\n" + usage + "\n").utf8))
            exit(2)
        }

        if options.showHelp {
            print(usage)
            return
        }

        let client = AtermClient()

        if let ip = options.singleIP {
            let device = await client.probe(ip: ip)
            emit(CLIFormatter.render(devices: [device].compactMap(\.self), clean: options.clean))
            if device == nil, !options.clean {
                print("\(ip) は Aterm ではないか、応答がありません。")
            }
            return
        }

        guard let range = SystemNetworkInfo().currentScanRange(), !range.targets.isEmpty else {
            FileHandle.standardError.write(Data("ネットワーク情報を取得できません。ネットワーク接続を確認してください。\n".utf8))
            exit(1)
        }

        if !options.clean {
            let first = range.targets.first ?? "-"
            let last = range.targets.last ?? "-"
            FileHandle.standardError.write(Data("検索範囲: \(first) - \(last) (\(range.interfaceName))\n検索中...\n".utf8))
        }

        let devices = await ScanEngine(prober: client).scan(targets: range.targets)
        emit(CLIFormatter.render(devices: devices, clean: options.clean))
    }

    /// 空文字は改行も出さない (clean モードの「結果行のみ」契約を守る)。
    private static func emit(_ output: String) {
        guard !output.isEmpty else { return }
        print(output)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let CLIOptions.ParseError.unknownArgument(arg):
            "不明な引数: \(arg)"
        case let CLIOptions.ParseError.missingValue(flag):
            "\(flag) には値が必要です"
        case let CLIOptions.ParseError.invalidIP(value):
            "IPv4 アドレスの形式が不正です: \(value)"
        default:
            "引数の解析に失敗しました"
        }
    }
}
