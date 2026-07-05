#!/bin/bash
# build-dmg.sh — 署名済み AtermDetector.app から配布用 DMG を作る。
# Applications へのシンボリックリンク + 背景画像 + アイコン配置で
# 「開いたらドラッグして入れるだけ」の一般的なレイアウトにする。
#
# 使い方:
#   scripts/build-dmg.sh <AtermDetector.app のパス> <出力 DMG パス> [署名 identity]
#
# 署名 identity 省略時は署名しない (ローカル確認用)。
set -euo pipefail

APP="${1:?usage: build-dmg.sh <app> <out.dmg> [identity]}"
OUT="${2:?usage: build-dmg.sh <app> <out.dmg> [identity]}"
IDENTITY="${3:-}"

VOL="AtermDetector"
HERE="$(cd "$(dirname "$0")" && pwd)"
BG="$HERE/dmg/background.png"
WIN_W=660
WIN_H=400
ICON_SIZE=128

work="$(mktemp -d)"
stage="$work/stage"
mnt="$work/mnt"
mkdir -p "$stage/.background" "$mnt"
trap 'hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
[ -f "$BG" ] && cp "$BG" "$stage/.background/background.png"

# 読み書き DMG を作成
rw="$work/rw.dmg"
hdiutil create -srcfolder "$stage" -volname "$VOL" -fs HFS+ \
  -format UDRW -ov "$rw" >/dev/null

# 一意なマウントポイントにマウント (= 既に同名 "$VOL" ボリュームが
# マウントされていても衝突しないよう /Volumes/$VOL を使わない)。
hdiutil attach "$rw" -mountpoint "$mnt" -nobrowse -noautoopen >/dev/null

# Finder でレイアウト設定。disk はボリューム名でなくマウントポイントから
# 特定するため、同名ボリュームが他にあっても曖昧にならない。
# (自動化権限が無い等で失敗しても DMG 自体は成立する)
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  set theDisk to disk of (POSIX file "$mnt" as alias)
  tell theDisk
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, ${WIN_W}+200, ${WIN_H}+120}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set background picture of opts to file ".background:background.png"
    set position of item "$VOL.app" of container window to {165, 175}
    set position of item "Applications" of container window to {495, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "[build-dmg] Finder レイアウト設定: OK"
  sync
else
  echo "[build-dmg] WARN: Finder 自動化不可 — 既定レイアウトで続行 (Applications リンクは表示されます)" >&2
fi

hdiutil detach "$mnt" -force >/dev/null 2>&1 || true

# 圧縮された配布用 DMG に変換
rm -f "$OUT"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "[build-dmg] created: $OUT"

# DMG を署名 (identity 指定時)
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
  echo "[build-dmg] signed with: $IDENTITY"
fi
