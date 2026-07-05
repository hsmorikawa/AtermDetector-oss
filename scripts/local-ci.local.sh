#!/bin/bash
# AtermDetector 固有 override — 本 repo では commit 対象 (macOS-only app のため)。
#
# local-ci.sh の template 既定 `ios_hook` は iOS Simulator family (iPhone 等) で
# `xcodebuild test` を実行するが、本 app は macOS-only target のため iOS destination
# ではビルド不能。設計済み拡張点 (early source + 関数 override) で macOS destination
# に差し替える。

ios_hook() {
    # project.yml と .xcodeproj の drift guard (template 提供関数を再利用)
    if ! _local_ci_ios_xcodegen_drift_check; then
        return 1
    fi
    xcodebuild test \
        -project AtermDetector.xcodeproj \
        -scheme AtermDetector \
        -destination 'platform=macOS' \
        -quiet || return 1
    # コマンドライン版もビルド確認 (テストは AtermDetector scheme に集約済み)
    xcodebuild build \
        -project AtermDetector.xcodeproj \
        -scheme aterm-cli \
        -destination 'platform=macOS' \
        -quiet
}
