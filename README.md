# AtermDetector

> ローカルネットワーク上の NEC Aterm ルーターを検出して一覧表示する macOS アプリ

Aterm の IP アドレスが分からなくても、起動するだけで同一ネットワーク内の Aterm を見つけ、クイック設定 Web (設定画面) をブラウザで開けます。

## 機能

- 起動時にサブネットを自動スキャンし、検出した Aterm を一覧表示 (機種名 / 動作モード / MAC アドレス / クイック設定 Web リンク)
- 再スキャンボタンでいつでも再検索
- 単一 IP デバッグ検索 (指定 IP への照会と生応答の確認)
- 一覧のリンクをクリックすると既定ブラウザで設定画面 (`http://<IP>`) を開く

## ダウンロード

ビルド済みバイナリ (Apple Silicon / Intel 両対応の universal binary) を **[最新リリース](../../releases/latest)** から入手できます。

| ファイル | 内容 |
|---|---|
| `AtermDetector-v*-macos-universal.zip` | GUI アプリ `AtermDetector.app` |
| `aterm-cli-v*-macos-universal.tar.gz` | コマンドライン版 `aterm-cli` |

コード署名・公証をしていない未署名バイナリのため、ダウンロード後は Gatekeeper の隔離属性を外してから実行してください。

```bash
# GUI アプリ (zip 解凍後)
xattr -dr com.apple.quarantine AtermDetector.app

# CLI (tar 解凍後)
tar xzf aterm-cli-v*-macos-universal.tar.gz
xattr -d com.apple.quarantine ./aterm-cli
```

自分でビルドする場合は下記 [Quick Start](#quick-start-開発) を参照してください。

## 検出の仕組み

1. **スキャン範囲の導出** — デフォルト経路のネットワークインタフェースから自ホストの IPv4 アドレスとサブネットマスクを取得し、`net4 = ip4 & mask4` を基点に最大 254 アドレスの範囲を決める (第 3 オクテットが 255 のマスクは `254 - mask4` 件、それより広いマスクは 254 件に丸めて注記)。
2. **HTTP 機器情報照会** — 範囲内の各アドレスへ以下を送る (認証不要・読み取り専用で、機器の設定は変更しない):

   ```
   POST http://<ip>/aterm_httpif.cgi/getparamcmd_no_auth
   Content-Type: application/x-www-form-urlencoded

   REQ_ID=PRODUCT_NAME_GET
   ```

3. **判定** — 応答 (CR/LF 除去後) が `PRODUCT_NAME=<機種名>` の形式なら、そのアドレスは Aterm。続けて `REQ_ID=SYS_MODE_GET` を送り、応答 `SYS_MODE=<番号>` を動作モード名に変換する:

   | 番号 | 動作モード | 番号 | 動作モード |
   |---|---|---|---|
   | 0 | ブリッジ | 6 | 464XLAT |
   | 1 | PPPoEルータ | 7 | DS-Lite |
   | 2 | ローカルルータ | 8 | 固定IP1 |
   | 3 | 無線LAN子機 | 9 | 複数固定IP |
   | 4 | 無線LAN中継機 | 10 | メッシュ中継機 |
   | 5 | MAP-E | 他 | "-" |

4. **MAC アドレスの解決** — 照会に応答した直後の機器はシステムの ARP テーブルにエントリが残っているため、routing table (sysctl `NET_RT_FLAGS`/`RTF_LLINFO`) を読んで IP → MAC を解決する (ブリッジモード機など、本体ラベルの MAC で個体を特定したい場合に有用)。未解決時は "-" 表示。
5. **並列実行** — 最大 32 並列・1 アドレスあたりタイムアウト 2 秒で照会し、検出結果を IP アドレス (最終オクテット) 昇順で表示する。/24 全域でも 30 秒以内に完了する。

## コマンドライン版 (aterm-cli)

GUI を使わずターミナルから検出したい場合や、結果をスクリプトで処理したい場合に使えます。バイナリは [ダウンロード](#ダウンロード) から入手できます。

```bash
# サブネット全体をスキャンして一覧表示
./aterm-cli

# clean モード: タブ区切り・ヘッダなし (パイプ / スクリプト向け)
./aterm-cli --clean            # IP<TAB>機種名<TAB>動作モード<TAB>MAC<TAB>URL

# 指定 IP のみをプローブ (デバッグ用)
./aterm-cli --ip 192.168.0.16

# ヘルプ
./aterm-cli --help
```

`--clean` は進捗などの付帯メッセージを stderr に流し、stdout には結果行だけを出すため、`| awk` や `| cut` でそのまま処理できます。

ソースからビルドする場合は `xcodegen generate && xcodebuild build -scheme aterm-cli -configuration Release -derivedDataPath build` で `build/Build/Products/Release/aterm-cli` が得られます。

## 動作環境

- macOS 14 以降 (Apple Silicon / Intel)
- **macOS 15 以降の注意**: 初回スキャン時に「ローカルネットワーク」の許可ダイアログが表示されます。拒否すると全プローブが無応答になり 0 件になります。その場合は「システム設定 > プライバシーとセキュリティ > ローカルネットワーク」で AtermDetector を許可し、アプリを再起動してください。

## Quick Start (開発)

```bash
brew install xcodegen swiftlint swiftformat

git clone https://github.com/hsmorikawa/AtermDetector.git
cd AtermDetector
xcodegen generate          # project.yml から .xcodeproj を再生成
open AtermDetector.xcodeproj

# CLI でテスト
xcodebuild test -scheme AtermDetector -destination 'platform=macOS'

# push 前のローカル CI 統合 gate
bash scripts/local-ci.sh
```

## Project Structure

```
AtermDetector/
├── project.yml            # XcodeGen 定義 (source of truth)
├── App/                   # SwiftUI GUI (エントリ / 一覧 / 単一IP検索シート)
├── CLI/                   # コマンドライン版 aterm-cli (Core を再利用)
├── Core/                  # UI 非依存ロジック (範囲導出 / HTTP 照会 / 並列スキャン / 状態管理)
├── Tests/                 # XCTest (URLProtocol mock / fake 注入)
├── specs/                 # Spec Kit 設計文書
└── scripts/local-ci.sh    # ローカル CI (lint / format / test / secrets)
```

## Tech Stack

Swift 6 / SwiftUI / XcodeGen / XCTest

## License

MIT

## Author

[@hsmorikawa](https://github.com/hsmorikawa)
