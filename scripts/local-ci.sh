#!/bin/bash
# ============================================================
# local-ci.sh — 多言語対応ローカル CI（GitHub CI 前段ゲート）
#
# 自動検出するスタック:
#   Python      — pyproject.toml / setup.py / requirements.txt
#   Node/TS     — package.json (root + web/, app/, frontend/, backend/, client/, server/, packages/)
#   Rust        — Cargo.toml
#   Swift       — Package.swift / *.xcodeproj / *.xcworkspace
#   Go          — go.mod
#   Gradle      — build.gradle / build.gradle.kts
#   Ruby        — Gemfile
#
# 共通: gitleaks（インストールされていれば常に走る）
#
# 拡張ポイント:
#   scripts/local-ci.pre.sh    プレフック（標準チェック前）
#   scripts/local-ci.post.sh   ポストフック（標準チェック後）
#   scripts/local-ci.local.sh  ローカル拡張（.gitignore で除外推奨、個人環境向け追加検証）
#
# 使い方:
#   ./scripts/local-ci.sh              全チェック実行
#   ./scripts/local-ci.sh --fast       遅いテストをスキップ（unit のみ）
#   ./scripts/local-ci.sh --no-test    テストをスキップ（lint/typecheck/secrets のみ）
#   ./scripts/local-ci.sh --only=rust  指定スタックのみ実行
#
# 環境変数 (warn-only gate の opt-out):
#   LOCAL_CI_SKIP_UI_TEST_GATE=1  UI ファイル変更時の UI/e2e テスト同梱 warn を抑止
#
# 終了コード:
#   0 = ALL GREEN（実行されたチェックが全て成功）
#   1 = 失敗あり（検出スタックでチェックが失敗）→ push ブロック対象
#   2 = warning-only（検出されたがツール未インストール / 未対応言語のみ）
#       → pre-push hook はこれを許容して push を通し、GitHub CI に委ねる
#
# bash 3.2 互換 (macOS /bin/bash) — associative array 不使用
# ============================================================
set -uo pipefail

cd "$(dirname "$0")/.."

# ============================================================
# PATH 補完（pre-push hook は zsh interactive 設定を読まないため、
#            ~/.zshrc 経由で追加されるツールパスを明示的に入れる）
# ============================================================
for _d in /opt/homebrew/bin /usr/local/bin "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/go/bin" "$HOME/.bun/bin"; do
  if [ -d "$_d" ] && ! echo ":$PATH:" | grep -q ":$_d:"; then
    PATH="$_d:$PATH"
  fi
done
unset _d
export PATH

FAST="false"
SKIP_TEST="false"
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)    FAST="true"; shift ;;
    --no-test) SKIP_TEST="true"; shift ;;
    --only)    ONLY="$2"; shift 2 ;;
    --only=*)  ONLY="${1#*=}"; shift ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# === LOAD GUARD BEGIN ===
# Machine-load pre-flight guard。push 前の local CI 起動時に 1-min loadavg を
# CPU 数ベースの threshold と比較し、過負荷なら警告して exit 2 (= warning-only、
# push は block しない)。純関数として実装し exit は呼ばない (= bats unit-test 可)、
# call-site が return-code 2 を `exit 2` に変換する。

# CPU 数を解決する: sysctl -n hw.ncpu (macOS) → nproc (Linux) → 絶対 fallback (= 4)。
# 各候補が positive integer であることを検証してから採用し、そうでなければ次へ。
# 全候補が失敗しても必ず 4 を echo して return 0 する (= 過負荷 threshold の分母を
# 常に確定させる)。bash 3.2 互換 (= case glob で数値判定、連想配列 / bc 不使用)。
_LOCAL_CI_CPU_COUNT_FALLBACK=4
_local_ci_cpu_count() {
  local n=""
  if command -v sysctl >/dev/null 2>&1; then
    n=$(sysctl -n hw.ncpu 2>/dev/null)
  fi
  case "$n" in
    ''|*[!0-9]*) n="" ;;
    0) n="" ;;
  esac
  if [ -z "$n" ] && command -v nproc >/dev/null 2>&1; then
    n=$(nproc 2>/dev/null)
    case "$n" in
      ''|*[!0-9]*) n="" ;;
      0) n="" ;;
    esac
  fi
  [ -z "$n" ] && n="$_LOCAL_CI_CPU_COUNT_FALLBACK"
  echo "$n"
  return 0
}

# uptime 1 行 ($1) から 1-min loadavg を抽出する。BSD (`load averages: X Y Z`、
# space 区切り) と Linux (`load average: X, Y, Z`、comma 区切り) の両フォーマットを
# 単一 sed -E で扱う: `load average[s]?:` の後、最初の token (= space / comma 直前まで)
# を捕捉する (= trailing comma 許容)。捕捉できない / 数値でない場合は non-zero + 空出力で
# 返す (= 解析失敗を呼び側が threshold 比較せず skip できるようにする)。bash 3.2 互換。
_local_ci_parse_loadavg() {
  local line="$1"
  local tok
  tok=$(printf '%s\n' "$line" \
    | sed -nE 's/.*load average[s]?:[[:space:]]*([^,[:space:]]+).*/\1/p')
  case "$tok" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  printf '%s\n' "$tok"
  return 0
}

# 過負荷判定の上限 (= threshold) を echo する。default は 4 × _local_ci_cpu_count。
# LOCAL_CI_MAX_LOAD が positive integer のときだけ override として採用し、garbage
# (= 非数値 / 0 / 空) は無視して default に fall back する (= 誤設定で guard を無効化
# させない)。常に return 0 (= 比較の分母を確定させる)。bash 3.2 互換 (= case glob で数値判定)。
_local_ci_load_threshold() {
  local override="${LOCAL_CI_MAX_LOAD:-}"
  case "$override" in
    ''|*[!0-9]*|0) ;;
    *) echo "$override"; return 0 ;;
  esac
  echo $(( 4 * $(_local_ci_cpu_count) ))
  return 0
}

# Machine-load guard の orchestrator。status code のみ返し自身では exit しない
# (= bats `run` 下で単体検証可、call-site が return-code 2 を `exit 2` に翻訳する)。
#   - LOCAL_CI_SKIP_LOAD_CHECK=1 → guard 全体 skip (= return 0)
#   - uptime 不在 / 出力 parse 不能 → best-effort で続行 (= return 0、押し止めない)
#   - 1-min loadavg > threshold → `⚠ machine overloaded: load=X > threshold=Y; ...` を
#     stderr に出して return 2 (= warning-only defer)
#   - それ以外 (= load <= threshold) → return 0
# float 比較は awk (= bash 3.2 は浮動小数比較不可、bc 不使用)。bash 3.2 互換。
_local_ci_load_guard() {
  if [ "${LOCAL_CI_SKIP_LOAD_CHECK:-0}" = "1" ]; then
    return 0
  fi
  command -v uptime >/dev/null 2>&1 || return 0
  local line load threshold
  line=$(uptime 2>/dev/null)
  load=$(_local_ci_parse_loadavg "$line") || return 0
  [ -z "$load" ] && return 0
  threshold=$(_local_ci_load_threshold)
  # load > threshold を awk で判定 (= 浮動小数比較)。over なら exit 0 (= !(l>t) が false)。
  if awk -v l="$load" -v t="$threshold" 'BEGIN { exit !(l > t) }'; then
    echo "[local-ci] ⚠ machine overloaded: load=$load > threshold=$threshold; local CI を defer します (= exit 2、push は block しません)。" >&2
    echo "[local-ci]   強制実行: LOCAL_CI_SKIP_LOAD_CHECK=1 / 閾値変更: LOCAL_CI_MAX_LOAD=<n>" >&2
    return 2
  fi
  return 0
}
# === LOAD GUARD END ===

# === RUN LOCK BEGIN ===
# Concurrent-run lock。mkdir-atomic な lock dir を取り、同一 repo で local CI の
# 二重起動を defer する。lock 内に PID を記録し、PID が既に死んでいれば stale lock
# として recover する。lock 取得失敗時は警告して exit 2 (= defer、push を block しない)。
# 純関数として実装し exit は呼ばない (= bats unit-test 可)、call-site が return-code 2
# を `exit 2` に変換する。

# repo-keyed な lock key を echo する (= predictable、同一 repo で必ず同じ key)。
# 構成: sanitize(basename) + "-" + short hash(absolute path)。
#   - basename: git toplevel basename を第一候補とし、git 外なら cwd basename に fallback。
#   - hash: toplevel 絶対 path を cksum (= POSIX、BSD/Linux 両対応) に通した第 1 field。
#           同一 basename でも path が異なれば hash が変わり key が衝突しない。
# sanitize: [A-Za-z0-9._-] 以外を '_' に潰す (= lock dir 名として安全)。空になったら 'repo'。
# 常に return 0 (= lock path の確定性を担保)。bash 3.2 互換 (= 連想配列 / bc 不使用)。
_local_ci_repo_lock_key() {
  local top=""
  if command -v git >/dev/null 2>&1; then
    top=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  [ -z "$top" ] && top="$PWD"
  local base
  base=$(basename "$top")
  # sanitize: 安全 charset 以外を '_' に置換。
  local safe
  safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
  [ -z "$safe" ] && safe="repo"
  # 絶対 path の short hash (= cksum 第 1 field、桁数可変だが数値なので安全 charset)。
  local hash
  hash=$(printf '%s' "$top" | cksum | awk '{print $1}')
  [ -z "$hash" ] && hash="0"
  printf '%s-%s\n' "$safe" "$hash"
  return 0
}

# lock dir/file の絶対 path を echo する。${TMPDIR:-/tmp}/local-ci-<key>.lock の形。
# TMPDIR の末尾 '/' は除去して二重スラッシュを避ける。常に return 0。bash 3.2 互換。
_local_ci_lock_path() {
  local dir="${TMPDIR:-/tmp}"
  # 末尾スラッシュを 1 個だけ除く (= /tmp/ → /tmp、/ は触らない)。
  case "$dir" in
    /) ;;
    */) dir="${dir%/}" ;;
  esac
  printf '%s/local-ci-%s.lock\n' "$dir" "$(_local_ci_repo_lock_key)"
  return 0
}

# lock dir ($1) を mkdir-atomic に取得する。取得できたら $1/pid に自 PID を記録して
# return 0。既に存在する場合は $1/pid の PID を読み:
#   - pid 不在 / 不正 (= 別 run が mkdir 直後・pid 書込前の初期化中かもしれない) → steal せず
#     短い retry (LOCAL_CI_LOCK_INIT_RETRIES × LOCAL_CI_LOCK_INIT_SLEEP) で pid 確定を待ち、
#     確定しなければ live とみなし return 2 (= defer)。live lock を rm -rf しない (= codex P2 TOCTOU 回避)
#   - 有効な数値 PID が生存 (= 別 run が実行中)  → 警告して return 2 (= defer、call-site が exit 2)
#   - 有効な数値 PID が死亡 (= 明確に stale)     → rm -rf で steal し単一 retry。成功で return 0、
#                                                  retry も負ければ (= race で別 run に奪われた等) return 2
# LOCAL_CI_NO_LOCK=1 なら lock を完全に skip し dir を作らず return 0 (= CI / 明示無効化)。
# exit は呼ばない (= bats unit-test 可)。bash 3.2 互換 (= 連想配列 / bc 不使用)。
_local_ci_acquire_lock() {
  local lock="$1"
  # LOCAL_CI_SKIP_LOAD_CHECK と同じく explicit '1' のときだけ skip。falsy な '0' / 'false' を
  # 「off」既定値として export しても concurrency 保護を黙って無効化させない (= codex P3 2026-06-14)。
  if [ "${LOCAL_CI_NO_LOCK:-0}" = "1" ]; then
    return 0
  fi
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"
    # 取得した lock path を module-level に記録する (= call-site の trap が参照して解放)。
    # 関数自身は trap を張らない (= status を返す純関数のまま、unit-test の run subshell で
    # 即解放されない)。trap 登録は call-site (= script 実行時のみ通る経路) が担う。
    _LCI_LOCK_PATH="$lock"
    return 0
  fi
  # mkdir 失敗 = 既存 lock。記録 PID を読む。ここで重要なのは「pid ファイルが無い / 数値でない」
  # を即 stale 扱いして steal しないこと (= codex P2 TOCTOU): 別 run が mkdir 成功直後・pid 書込前の
  # 一瞬を捉えると pid が空に見える。それを stale とみなして rm -rf すると live lock を消して
  # 二重起動を許す。pid 不在 / 不正は「初期化中 = live かもしれない」とみなし、短い retry で
  # pid が確定するのを待つ。retry 後も確定しなければ steal せず defer (= 安全側)。
  local retries="${LOCAL_CI_LOCK_INIT_RETRIES:-10}"
  case "$retries" in ''|*[!0-9]*) retries=10 ;; esac
  local sleep_s="${LOCAL_CI_LOCK_INIT_SLEEP:-0.1}"
  local other="" i=0
  while :; do
    other=""
    [ -f "$lock/pid" ] && other=$(cat "$lock/pid" 2>/dev/null)
    case "$other" in
      ''|*[!0-9]*) other="" ;;
    esac
    # 有効な数値 PID が読めた → 死活判定へ抜ける。
    [ -n "$other" ] && break
    # pid 未確定 (= 不在 / 不正) → 初期化中とみなし retry。上限到達で defer。
    [ "$i" -ge "$retries" ] && {
      echo "[local-ci] 別の local CI が起動中 (lock $lock に有効な PID が確定しません)。二重起動を defer します (= exit 2、push は block しません)。" >&2
      echo "[local-ci]   強制スキップ: LOCAL_CI_NO_LOCK=1 / 残骸除去: rm -rf '$lock'" >&2
      return 2
    }
    i=$((i + 1))
    sleep "$sleep_s" 2>/dev/null || true
  done
  if kill -0 "$other" 2>/dev/null; then
    echo "[local-ci] 別の local CI が実行中 (PID $other)。二重起動を defer します (= exit 2、push は block しません)。" >&2
    echo "[local-ci]   強制スキップ: LOCAL_CI_NO_LOCK=1 / 残骸除去: rm -rf '$lock'" >&2
    return 2
  fi
  # ここに来るのは「有効な数値 PID だが当該 PID が死んでいる」ケースのみ (= 明確に stale)。
  # → steal して単一 retry。pid 不在 / 不正は上の retry で既に defer 済なので steal しない。
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"
    _LCI_LOCK_PATH="$lock"
    return 0
  fi
  echo "[local-ci] stale lock (PID $other 死亡) の steal 後 retry に失敗 ($lock)。二重起動を defer します (= exit 2)。" >&2
  return 2
}

# lock dir ($1) を解放する。記録 path のみを対象に rm -rf する (= trap からも安全に呼べる)。
# 既に無い場合は no-op で return 0。空 path は誤って広域削除しないよう何もしない。bash 3.2 互換。
_local_ci_release_lock() {
  local lock="$1"
  [ -z "$lock" ] && return 0
  rm -rf "$lock"
  return 0
}
# === RUN LOCK END ===

# === UI TEST GATE BEGIN ===
# §11 UI テスト gate (= AGENTS.md §11 / spec 022 A2)。push 範囲が UI ファイルを
# 変更しているのに UI/e2e テストファイルの変更を含まないとき warn する (= 純粋な
# warning、exit code に影響しない・FAILED=1 を立てない・block しない)。§11 の完全
# 自動 enforcement は heuristic 誤検知しうるため pragmatic な可視化に徹する (= README
# warn / spec 015 と同型の warn-only 思想)。純関数として実装し自身では exit しない
# (= bats `run` 下で単体検証可)。bash 3.2 互換 (= 連想配列不使用、case glob で判定)。

# push 範囲の変更ファイル名を 1 行ずつ echo する seam (= bats が override 可能)。
#   1) staged 変更 (`git diff --cached --name-status`) — push 直前の検査と同方針
#   2) 未 push commit 範囲の変更ファイル (= origin/HEAD → main → master → ... を順に試行)
#   両者の UNION を出す (= dirty-worktree で staged 変更と未 push UI commit が同時にあっても
#   UI commit を取りこぼさない、Codex P3)。重複は sort -u で 1 回に畳む。
#   削除 (= status 'D') は除外する (= 削除された spec を「テスト変更あり」と誤判定して
#   §11 warn を握り潰さない、また削除された UI ファイルを「UI 変更」に数えない、Codex P3)。
#   git 外 / 取得不能 → 空 (= 判定対象なし、無言)。
# 名前のみ読み、build は一切起こさない。常に return 0。
_local_ci_changed_files() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local staged unpushed
  staged=$(git diff --cached --name-status 2>/dev/null)
  local default_branch="" head_ref cand range=""
  if head_ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
    default_branch="${head_ref#refs/remotes/origin/}"
  fi
  local candidates="@{u}"
  [ -n "$default_branch" ] && candidates="$candidates origin/$default_branch"
  candidates="$candidates origin/main origin/master origin/develop origin/trunk"
  for cand in $candidates; do
    if git rev-parse --verify "$cand" >/dev/null 2>&1; then
      range="$(git rev-parse "$cand")..HEAD"
      break
    fi
  done
  [ -n "$range" ] && unpushed=$(git diff --name-status "$range" 2>/dev/null)
  # staged ∪ unpushed の name-status から削除 (D...) 行を除き、最終パス列のみを出力する。
  # awk: 1 列目が D で始まる行は skip、それ以外は最後のフィールド (= rename も新名を採用)
  # を出す。空行は除き sort -u で de-dup する。
  printf '%s\n%s\n' "$staged" "$unpushed" \
    | awk 'NF && $1 !~ /^D/ { print $NF }' \
    | sort -u
  return 0
}

# 1 ファイル名 ($1) が UI ファイル heuristic に該当するか (= spec AC15 列挙)。
# *.tsx / *.jsx / *.vue / *.svelte / src/**/components/** 等。該当で return 0。
_local_ci_is_ui_file() {
  case "$1" in
    *.tsx|*.jsx|*.vue|*.svelte) return 0 ;;
    */components/*|components/*) return 0 ;;
  esac
  return 1
}

# 1 ファイル名 ($1) が UI/e2e テストファイル heuristic に該当するか (= spec AC16 列挙)。
# *.spec.ts[x] / *.e2e.* / tests/e2e/** / *.test.tsx[x] / *.cy.* 等。該当で return 0。
# UI ファイル判定より先に評価する (= テストファイルを UI ファイルに誤分類しない)。
_local_ci_is_ui_test_file() {
  case "$1" in
    *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) return 0 ;;
    *.test.tsx|*.test.jsx) return 0 ;;
    *.e2e.*|*.cy.*) return 0 ;;
    e2e/*|*/e2e/*) return 0 ;;
  esac
  return 1
}

# UI テスト gate 本体。changed-file seam を走査し、UI ファイルが含まれ・UI/e2e テスト
# ファイルが含まれないときだけ stderr に warn を出して return 0。それ以外 (= UI 変更なし /
# UI+テスト両方変更 / opt-out) は無言で return 0。常に return 0 (= block しない)。
_local_ci_ui_test_gate() {
  # opt-out: explicit '1' のときだけ skip (= 他の force-run escape hatch と同方針)。
  if [ "${LOCAL_CI_SKIP_UI_TEST_GATE:-0}" = "1" ]; then
    return 0
  fi
  local has_ui=0 has_ui_test=0 f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # テスト判定を先に行い、テストファイルを UI ファイルに二重計上しない。
    if _local_ci_is_ui_test_file "$f"; then
      has_ui_test=1
      continue
    fi
    if _local_ci_is_ui_file "$f"; then
      has_ui=1
    fi
  done <<EOF
$(_local_ci_changed_files)
EOF
  if [ "$has_ui" -eq 1 ] && [ "$has_ui_test" -eq 0 ]; then
    echo "[local-ci] ⚠ UI ファイルを変更していますが UI/e2e テスト (= *.spec.ts / *.e2e.* / tests/e2e/** / *.test.tsx 等) の変更が含まれていません。" >&2
    echo "[local-ci]   AGENTS.md §11: UI 変更には UI テストの追加・更新を必須成果物としてください (= push は block しません、warn-only)。" >&2
    echo "[local-ci]   抑止: LOCAL_CI_SKIP_UI_TEST_GATE=1" >&2
  fi
  return 0
}
# === UI TEST GATE END ===

# ============================================================
# Pre-flight guard call-sites (= arg-parse 直後・pre-hook 直前)。
# 上の marker block 内の純関数は自身では exit せず status code を返すだけなので、
# ここで return-code 2 を `exit 2` (= warning-only defer) に翻訳する thin な呼び出しを置く。
#   1. machine-load guard  — 高負荷なら exit 2 (= push は通し GitHub CI に委ねる)
#   2. concurrent-run lock — 別 run 実行中なら exit 2 (= defer)、acquire 成功時 trap で解放
# ============================================================
_local_ci_load_guard; _lci_rc=$?
[ "$_lci_rc" -eq 2 ] && exit 2
_local_ci_acquire_lock "$(_local_ci_lock_path)"; _lci_rc=$?
[ "$_lci_rc" -eq 2 ] && exit 2
# acquire 成功 (= return 0) のときだけ、どの exit 経路でも lock を解放する trap を張る。
# trap 登録を call-site (= script 実行時のみ通る) に置くことで、_local_ci_acquire_lock を
# 純関数 (= status のみ返す) に保ち、bats `run` subshell で lock dir が即解放されない。
[ -n "${_LCI_LOCK_PATH:-}" ] && trap '_local_ci_release_lock "$_LCI_LOCK_PATH"' EXIT

# §11 UI テスト gate (= spec 022 A2)。warn-only なので exit には翻訳せず、check 実行前に
# 1 度だけ呼んで「UI 変更あり・UI/e2e テスト変更なし」を可視化する (= push は block しない)。
_local_ci_ui_test_gate || true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

FAILED=0
STEPS=()
WARNINGS=()

run_step() {
  local name="$1"; shift
  echo ""
  printf "${BLUE}===> %s${RESET}\n" "$name"
  if "$@"; then
    STEPS+=("✓ $name")
  else
    STEPS+=("✗ $name")
    FAILED=1
  fi
}

run_step_in() {
  # サブディレクトリでステップを実行
  local dir="$1"; shift
  local name="$1"; shift
  echo ""
  printf "${BLUE}===> [%s] %s${RESET}\n" "$dir" "$name"
  if ( cd "$dir" && "$@" ); then
    STEPS+=("✓ [$dir] $name")
  else
    STEPS+=("✗ [$dir] $name")
    FAILED=1
  fi
}

warn() {
  WARNINGS+=("⚠ $1")
}

is_active() {
  [ -z "$ONLY" ] && return 0
  [ "$ONLY" = "$1" ] && return 0
  return 1
}

has_files() {
  # $1 = directory, $2... = patterns
  local dir="$1"; shift
  for p in "$@"; do
    if compgen -G "$dir/$p" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# ============================================================
# プレフック
# ============================================================
if [ -f scripts/local-ci.pre.sh ]; then
  run_step "pre-hook (scripts/local-ci.pre.sh)" bash scripts/local-ci.pre.sh
fi

# ============================================================
# Python
# ============================================================
HAS_PY="false"
if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  HAS_PY="true"
fi
if [ "$HAS_PY" = "true" ] && is_active "python"; then
  PY_HAS_SRC="false"
  if [ -d src ] && [ -n "$(find src -name '*.py' -type f 2>/dev/null | head -1)" ]; then
    PY_HAS_SRC="true"
  fi

  # ランナー選択: uv 優先、無ければ python -m fallback（uv 必須前提の暗黙化を回避）
  PY_RUNNER=""
  if command -v uv >/dev/null 2>&1; then
    PY_RUNNER="uv run"
  elif command -v python3 >/dev/null 2>&1; then
    PY_RUNNER="python3 -m"
    warn "Python: uv なし → python3 -m にフォールバック（推奨は 'brew install uv'）"
  elif command -v python >/dev/null 2>&1; then
    PY_RUNNER="python -m"
    warn "Python: uv なし → python -m にフォールバック"
  fi

  if [ -n "$PY_RUNNER" ]; then
    # Python ツールの実行可能性チェック（PY_RUNNER 経由）
    # 「設定ファイルにエントリあり」と「実際にツールがインストール済み」は別。
    # 未インストールは exit 2 (warning-only) ではなく、ステップ自体をスキップして警告に。
    py_tool_available() {
      $PY_RUNNER "$1" --version >/dev/null 2>&1
    }

    if [ -f pyproject.toml ]; then
      if grep -q '\[tool.ruff' pyproject.toml 2>/dev/null; then
        if py_tool_available ruff; then
          run_step "ruff format check" $PY_RUNNER ruff format --check .
          run_step "ruff lint"          $PY_RUNNER ruff check .
        else
          warn "Python: [tool.ruff] あるが ruff 未インストール — スキップ ('uv add --dev ruff' か 'pipx install ruff')"
        fi
      else
        warn "Python: pyproject.toml に [tool.ruff] が無い。ruff チェックをスキップ"
      fi
      if [ "$PY_HAS_SRC" = "true" ]; then
        if py_tool_available mypy; then
          run_step "mypy --strict" $PY_RUNNER mypy --strict src/
        else
          warn "Python: mypy 未インストール — スキップ"
        fi
      else
        warn "Python: src/*.py が無いため mypy をスキップ"
      fi
    else
      warn "Python: pyproject.toml が無い。lint/typecheck はスキップ"
    fi

    if [ "$SKIP_TEST" = "false" ]; then
      if [ -d tests ] || grep -q '\[tool.pytest' pyproject.toml 2>/dev/null; then
        if py_tool_available pytest; then
          if [ "$FAST" = "true" ]; then
            # 注: pyproject.toml の addopts に -m "not e2e and not perf" 等が指定されていると
            #     CLI 側の -m が addopts を上書きして除外条件が消える。
            #     除外したい marker は addopts と明示再指定を統合する必要がある。
            #     ここではプロジェクト共通で使われがちな slow/e2e/perf を全部除外する。
            run_step "pytest (fast)" $PY_RUNNER pytest -m "not slow and not e2e and not perf" --timeout=30
          else
            run_step "pytest" $PY_RUNNER pytest
          fi
        else
          warn "Python: pytest 未インストール — スキップ"
        fi
      else
        warn "Python: tests/ も pytest 設定も無い — pytest をスキップ"
      fi
    fi
  else
    warn "Python 検出されたが uv も python もコマンドなし。Python ランタイムを導入してください"
  fi
fi

# ============================================================
# Node/TS — root + monorepo subdirs
# ============================================================
PKG_MGR="pnpm"
command -v pnpm >/dev/null 2>&1 || PKG_MGR="npm"

run_node_checks() {
  local dir="$1"
  local label="$2"

  if [ ! -f "$dir/package.json" ]; then return; fi

  if grep -q '"lint"' "$dir/package.json" 2>/dev/null; then
    run_step_in "$dir" "${label} lint" $PKG_MGR run lint
  else
    warn "$label: package.json に lint script なし — スキップ"
  fi

  if grep -q '"typecheck"' "$dir/package.json" 2>/dev/null; then
    run_step_in "$dir" "${label} typecheck" $PKG_MGR run typecheck
  else
    warn "$label: package.json に typecheck script なし — スキップ"
  fi

  if [ "$SKIP_TEST" = "false" ]; then
    if grep -q '"test"' "$dir/package.json" 2>/dev/null; then
      if [ "$FAST" = "true" ]; then
        run_step_in "$dir" "${label} test (fast)" $PKG_MGR run test --silent
      else
        run_step_in "$dir" "${label} test" $PKG_MGR run test
      fi
    else
      warn "$label: test script なし — スキップ"
    fi
  fi
}

if is_active "node"; then
  if [ -f package.json ]; then
    run_node_checks "." "$PKG_MGR"
  fi
  for sub in web app frontend backend client server packages; do
    if [ -f "$sub/package.json" ]; then
      run_node_checks "$sub" "$PKG_MGR($sub)"
    fi
  done
fi

# ============================================================
# Rust
# ============================================================
if [ -f Cargo.toml ] && is_active "rust"; then
  if command -v cargo >/dev/null 2>&1; then
    run_step "cargo fmt --check" cargo fmt --all -- --check
    if cargo clippy --version >/dev/null 2>&1; then
      run_step "cargo clippy" cargo clippy --all-targets --all-features -- -D warnings
    else
      warn "Rust: clippy 未インストール ('rustup component add clippy')"
    fi
    if [ "$SKIP_TEST" = "false" ]; then
      run_step "cargo test" cargo test --all
    fi
  else
    warn "Cargo.toml 検出されたが cargo コマンドなし。rustup を導入"
  fi
fi

# === iOS HOOK BEGIN ===
# iOS Simulator-First Testing Policy hook (= AGENTS.md §12 / ADR 0031 / spec 002).
# `_local_ci_ios_default_hook` を Xcode project 検出時に呼ぶ。
# project 個別 `scripts/local-ci.local.sh` で `ios_hook()` を再定義すると override 可。

: "${LOCAL_CI_IOS_FAMILIES_DEFAULT:=iPhone}"

# xcodegen drift guard (= dev new --kind ios scaffold / ADR 0032)。
# project.yml が source of truth、.xcodeproj はコミット済だが手編集や
# project.yml 更新忘れで両者が drift しうる。push 前に xcodegen generate
# し直して `git diff` で .xcodeproj に差分が出たら FAIL させ、再生成 +
# コミットを促す。
#   - project.yml 不在 → silently skip (= 非 xcodegen project)
#   - SKIP_XCODEGEN_DRIFT_CHECK=1 → skip (= 緊急回避)
#   - xcodegen 未インストール → warn して skip (= guard を理由に block しない)
# 戻り値: 0 = drift なし / skip、1 = drift 検出 (= push を止める)
_local_ci_ios_xcodegen_drift_check() {
  if [ ! -f project.yml ]; then
    return 0
  fi
  if [ "${SKIP_XCODEGEN_DRIFT_CHECK:-0}" = "1" ]; then
    echo "[iOS Hook] xcodegen drift check: SKIPPED (SKIP_XCODEGEN_DRIFT_CHECK=1)" >&2
    return 0
  fi
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[iOS Hook] xcodegen drift check: SKIP (xcodegen 未インストール、'brew install xcodegen' 推奨)" >&2
    return 0
  fi
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[iOS Hook] xcodegen drift check: SKIP (git repo 外)" >&2
    return 0
  fi
  if ! xcodegen generate >/dev/null 2>&1; then
    echo "[iOS Hook] xcodegen drift check: FAIL (xcodegen generate がエラー、project.yml を確認)" >&2
    return 1
  fi
  # `.xcodeproj` はディレクトリ。`git diff` は tracked の変更しか見ず、未コミット
  # の新規 `.xcodeproj` (= untracked) を見逃すため、`git status --porcelain` で
  # tracked 変更 + untracked の両方を検出する (= Codex review P2)。
  if git status --porcelain 2>/dev/null | grep -q '\.xcodeproj/'; then
    echo "[iOS Hook] xcodegen drift check: FAIL — .xcodeproj が project.yml と drift、または未コミットです。" >&2
    echo "           'xcodegen generate' を実行し、再生成された .xcodeproj をコミットしてください。" >&2
    echo "           (緊急回避: SKIP_XCODEGEN_DRIFT_CHECK=1)" >&2
    return 1
  fi
  echo "[iOS Hook] xcodegen drift check: PASS (.xcodeproj は project.yml と一致)"
  return 0
}

_local_ci_ios_log_path() { echo "${LOGS_DIR:-logs}/local-ci-ios.log"; }
_local_ci_ios_summary_path() { echo "${LOGS_DIR:-logs}/local-ci-ios-summary.md"; }
_local_ci_ios_devlog_path() {
  local today="${TODAY:-$(date +%Y-%m-%d)}"
  echo "${DEVLOG_DIR:-devlog}/${today}.md"
}

_local_ci_ios_write_summary_skipped() {
  local reason="$1"
  mkdir -p "$(dirname "$(_local_ci_ios_summary_path)")"
  {
    echo "## local-ci-ios ($(date "+%Y-%m-%d %H:%M:%S %Z")) — SKIPPED"
    echo ""
    echo "**Reason**: $reason"
    echo "**By**: ${USER:-unknown}@${HOSTNAME:-unknown}"
  } > "$(_local_ci_ios_summary_path)"
}

_local_ci_ios_append_devlog() {
  local kind="$1"
  local detail="$2"
  local devlog
  devlog="$(_local_ci_ios_devlog_path)"
  mkdir -p "$(dirname "$devlog")"
  {
    echo ""
    echo "## $(date +%H:%M) local-ci-ios ${kind}"
    if [ "$kind" = "run" ]; then
      echo "- Result: $detail"
      echo "- Families: ${_LCIOS_FAMILIES_TESTED:-}"
      echo "- Summary: $(_local_ci_ios_summary_path)"
    else
      echo "- Reason: $detail"
      echo "- Summary: $(_local_ci_ios_summary_path)"
    fi
  } >> "$devlog"
}

_local_ci_ios_runtime_available() {
  local family="$1"
  local prefix=""
  case "$family" in
    iPhone|iPad)  prefix="com.apple.CoreSimulator.SimRuntime.iOS-" ;;
    VisionPro)    prefix="com.apple.CoreSimulator.SimRuntime.xrOS-" ;;
    AppleWatch)   prefix="com.apple.CoreSimulator.SimRuntime.watchOS-" ;;
    *) return 1 ;;
  esac
  command -v xcrun >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  xcrun simctl list runtimes --json 2>/dev/null \
    | jq -e --arg p "$prefix" '.runtimes[]? | select(.identifier | startswith($p)) | select(.isAvailable == true)' \
    >/dev/null 2>&1
}

_local_ci_ios_destination_for() {
  # family → simctl runtime + device name prefix + platform + fallback (= Codex P2-D fix)。
  # 動的 selection: xcrun simctl list devices available --json から family 該当の latest device を選定。
  # 失敗時は fallback name を使用 (= 環境異常 / fake stub の case)。
  local family="$1"
  local runtime name_prefix platform fallback
  case "$family" in
    iPhone)     runtime="iOS-";    name_prefix="iPhone ";       platform="iOS Simulator";       fallback="iPhone 17 Pro" ;;
    iPad)       runtime="iOS-";    name_prefix="iPad ";         platform="iOS Simulator";       fallback="iPad Pro 13-inch (M5)" ;;
    VisionPro)  runtime="xrOS-";   name_prefix="Apple Vision";  platform="visionOS Simulator";  fallback="Apple Vision Pro" ;;
    AppleWatch) runtime="watchOS-"; name_prefix="Apple Watch";  platform="watchOS Simulator";   fallback="Apple Watch Series 10 (46mm)" ;;
    AppleTV)    runtime="tvOS-";   name_prefix="Apple TV";      platform="tvOS Simulator";      fallback="Apple TV 4K (3rd generation)" ;;
    *) return 1 ;;
  esac
  local device=""
  if command -v xcrun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    device=$(xcrun simctl list devices available --json 2>/dev/null \
      | jq -r --arg rp "com.apple.CoreSimulator.SimRuntime.${runtime}" --arg np "$name_prefix" \
        '.devices | to_entries[] | select(.key | startswith($rp)) | .value[] | select(.name | startswith($np)) | .name' 2>/dev/null \
      | sort -V | tail -1)
  fi
  [ -z "$device" ] && device="$fallback"
  echo "platform=${platform},name=${device},OS=latest"
}

_local_ci_ios_runtime_label_for() {
  local family="$1"
  case "$family" in
    iPhone|iPad) echo "iOS" ;;
    VisionPro) echo "visionOS" ;;
    AppleWatch) echo "watchOS" ;;
    *) echo "unknown" ;;
  esac
}

# Detect -workspace/-project + -scheme for xcodebuild (= ADR 0031 follow-up、Codex P1)。
# Priority: $LOCAL_CI_IOS_PROJECT_ARGS env override > xcworkspace > xcodeproj > Package.swift。
# Returns space-separated xcodebuild args (e.g. "-workspace ios/MyApp.xcworkspace -scheme MyApp")
# or empty if no project + no Package.swift found.
_local_ci_ios_detect_project_args() {
  # 1. 明示 override
  if [ -n "${LOCAL_CI_IOS_PROJECT_ARGS:-}" ]; then
    echo "$LOCAL_CI_IOS_PROJECT_ARGS"
    return 0
  fi

  local workspace project scheme
  # 2. xcworkspace 検出 (vendor 除外)、xcodebuild -list で scheme 取得
  workspace=$(find . -maxdepth 4 -name "*.xcworkspace" \
    -not -path "*/Pods/*" -not -path "*/Carthage/*" \
    -not -path "*/.build/*" -not -path "*/DerivedData/*" \
    -not -path "*/node_modules/*" 2>/dev/null | head -1)
  if [ -n "$workspace" ] && command -v xcodebuild >/dev/null 2>&1; then
    scheme=$(xcodebuild -workspace "$workspace" -list -json 2>/dev/null \
      | jq -r '.workspace.schemes[0] // empty' 2>/dev/null)
    if [ -n "$scheme" ]; then
      echo "-workspace $workspace -scheme $scheme"
      return 0
    fi
  fi

  # 3. xcodeproj 検出
  project=$(find . -maxdepth 4 -name "*.xcodeproj" \
    -not -path "*/Pods/*" -not -path "*/Carthage/*" \
    -not -path "*/.build/*" -not -path "*/DerivedData/*" \
    -not -path "*/node_modules/*" 2>/dev/null | head -1)
  if [ -n "$project" ] && command -v xcodebuild >/dev/null 2>&1; then
    scheme=$(xcodebuild -project "$project" -list -json 2>/dev/null \
      | jq -r '.project.schemes[0] // empty' 2>/dev/null)
    if [ -n "$scheme" ]; then
      echo "-project $project -scheme $scheme"
      return 0
    fi
  fi

  # 4. Package.swift (SPM) — name attribute から scheme 取得 (-project/-workspace なし、cwd 前提)
  if [ -f Package.swift ]; then
    scheme=$(grep -E 'name:[[:space:]]*"' Package.swift 2>/dev/null | head -1 \
      | sed -E 's/.*name:[[:space:]]*"([^"]+)".*/\1/')
    if [ -n "$scheme" ]; then
      echo "-scheme $scheme"
      return 0
    fi
  fi

  # 検出失敗 (= 開発者は LOCAL_CI_IOS_PROJECT_ARGS で明示指定するか ios_hook を override)
  return 1
}

_local_ci_ios_run_one() {
  local family="$1"
  local dest
  dest="$(_local_ci_ios_destination_for "$family")" || { echo "FAIL|0|unknown|unknown"; return 1; }
  local start_ts end_ts elapsed
  start_ts=$(date +%s)

  local extra_flags=()
  if [ -n "${LOCAL_CI_IOS_XCODEBUILD_EXTRA_FLAGS:-}" ]; then
    # shellcheck disable=SC2206
    extra_flags=(${LOCAL_CI_IOS_XCODEBUILD_EXTRA_FLAGS})
  fi
  local log
  log="$(_local_ci_ios_log_path)"
  mkdir -p "$(dirname "$log")"

  # auto-detect -workspace/-project + -scheme (= ADR 0031 P1 follow-up)
  local project_args=""
  local proj_args_out
  if proj_args_out=$(_local_ci_ios_detect_project_args); then
    project_args="$proj_args_out"
  fi
  # shellcheck disable=SC2206
  local proj_args_arr=(${project_args})

  xcodebuild test \
    "${proj_args_arr[@]+"${proj_args_arr[@]}"}" \
    -destination "$dest" \
    -parallel-testing-enabled YES \
    -quiet \
    -disableAutomaticPackageResolution \
    "${extra_flags[@]+"${extra_flags[@]}"}" >>"$log" 2>&1
  local rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  local device_name
  device_name=$(echo "$dest" | sed -nE 's/.*name=([^,]+).*/\1/p')
  local runtime_label
  runtime_label=$(_local_ci_ios_runtime_label_for "$family")

  if [ $rc -eq 0 ]; then
    echo "PASS|$elapsed|$runtime_label|$device_name"
    return 0
  else
    echo "FAIL|$elapsed|$runtime_label|$device_name"
    return 1
  fi
}

_local_ci_ios_default_hook() {
  # Skip 経路 (= LOCAL_CI_IOS_SKIP)
  local skip_state="${LOCAL_CI_IOS_SKIP-__UNSET__}"
  if [ "$skip_state" != "__UNSET__" ]; then
    if [ -z "$skip_state" ] || [ "$skip_state" = "1" ] || [ "$skip_state" = "true" ]; then
      echo "[iOS Hook] ERROR: LOCAL_CI_IOS_SKIP reason required (empty / '1' / 'true' は不可)" >&2
      return 2
    fi
    _local_ci_ios_write_summary_skipped "$skip_state"
    _local_ci_ios_append_devlog "skipped" "$skip_state"
    echo "[iOS Hook] SKIPPED: $skip_state"
    return 0
  fi

  # xcodegen drift guard (= ADR 0032)。xcodebuild より前に実行し、
  # .xcodeproj が project.yml と drift していたら push を止める。
  if ! _local_ci_ios_xcodegen_drift_check; then
    return 1
  fi

  # Family list (= override env var > default)
  local families
  families="${LOCAL_CI_IOS_FAMILIES:-$LOCAL_CI_IOS_FAMILIES_DEFAULT}"
  local family_arr=()
  IFS=',' read -ra family_arr <<< "$families"

  local n_pass=0 n_fail=0 n_skip=0 total_elapsed=0
  local rows=()
  local family
  for family in "${family_arr[@]}"; do
    # trim whitespace (= sed)
    family=$(echo "$family" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$family" ] && continue

    if ! _local_ci_ios_runtime_available "$family"; then
      echo "[iOS Hook] $family: SKIP (runtime unavailable)" >&2
      rows+=("| $family | SKIP | 0s | n/a | n/a |")
      n_skip=$((n_skip + 1))
      continue
    fi

    local result rc
    result=$(_local_ci_ios_run_one "$family")
    rc=$?
    local status elapsed runtime device
    IFS='|' read -r status elapsed runtime device <<< "$result"
    rows+=("| $family | $status | ${elapsed}s | $runtime | $device |")
    total_elapsed=$((total_elapsed + elapsed))
    if [ "$status" = "PASS" ]; then
      n_pass=$((n_pass + 1))
    else
      n_fail=$((n_fail + 1))
    fi
    [ $rc -eq 0 ] || true  # 1 family fail でも継続
  done

  # Summary 出力
  _LCIOS_FAMILIES_TESTED="$families"
  local summary
  summary="$(_local_ci_ios_summary_path)"
  mkdir -p "$(dirname "$summary")"
  {
    echo "## local-ci-ios ($(date "+%Y-%m-%d %H:%M:%S %Z"))"
    echo ""
    echo "| Family | Result | Time | Runtime | Device |"
    echo "|---|---|---|---|---|"
    if [ ${#rows[@]} -gt 0 ]; then
      printf '%s\n' "${rows[@]}"
    fi
    echo ""
    echo "**Total**: $n_pass PASS / $n_fail FAIL / $n_skip SKIP / ${total_elapsed}s"
  } > "$summary"

  _local_ci_ios_append_devlog "run" "$n_pass PASS / $n_fail FAIL / $n_skip SKIP / ${total_elapsed}s"

  if [ $n_fail -gt 0 ]; then
    return 1
  fi
  return 0
}

# Override extension: project の scripts/local-ci.local.sh で `ios_hook()` を定義すると delegate
# template 側 default は default hook を素通しで呼ぶ。下の早期 source で local-ci.local.sh が
# 読み込まれた時点で関数 override が effective になる (= Codex P2-B fix)。
ios_hook() {
  _local_ci_ios_default_hook "$@"
}
# === iOS HOOK END ===

# === SWIFT PACKAGE BUILD STRATEGY (= local-ci xcodebuild fallback) ===
# SwiftPM CLI (`swift build` / `swift test`) は Apple 内蔵の SwiftData macro plugin
# (`SwiftDataMacros`) を解決できず、`@Model` を使う package の build/test が必ず fail する。
# その場合 xcodebuild (= macro plugin を解決可) に fallback する。 SwiftData 非依存の
# package は従来通り `swift build` / `swift test` (= 速い + Linux parity 維持)。
# 方式は adaptive (= まず swift build/test、 SwiftData macro 由来で fail したら xcodebuild で
# 再実行)。 推移的依存で SwiftData を引く package も failure 伝播で自動的に拾える。

# Package.swift の name attribute → xcodebuild scheme 名の素朴推定 (= name == product 名の
# 一般ケース)。 _local_ci_swift_pkg_resolve_scheme の fallback として使う。
_local_ci_swift_pkg_scheme() {
  grep -E 'name:[[:space:]]*"' Package.swift 2>/dev/null | head -1 \
    | sed -E 's/.*name:[[:space:]]*"([^"]+)".*/\1/'
}

# xcodebuild が実際に認識する package scheme を解決する。
# `xcodebuild -list -json` を第一候補にし (= product 名が package 名と異なる package でも
# 正しい scheme を得る)、 取得できなければ Package.swift の name 推定に fallback する。
# fallback は現行挙動と等価なので、 -list 失敗でも回帰しない。
_local_ci_swift_pkg_resolve_scheme() {
  local scheme=""
  if command -v xcodebuild >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    scheme=$(xcodebuild -list -json 2>/dev/null \
      | jq -r '(.project.schemes // .workspace.schemes // .schemes // [])[0] // empty' 2>/dev/null)
  fi
  if [ -z "$scheme" ]; then
    scheme=$(_local_ci_swift_pkg_scheme)
  fi
  printf '%s' "$scheme"
}

# swift build / swift test の失敗出力が SwiftData macro plugin 解決失敗かを判定。
_local_ci_swift_is_swiftdata_macro_failure() {
  printf '%s' "$1" | grep -q 'SwiftDataMacros'
}

# Package.swift の platforms 宣言から xcodebuild destination を導出する。
# action=build は generic destination で可、 action=test は具体 device が要る。
# iOS を宣言する package は iOS Simulator (= 最一般、 macOS と両対応でも iOS を採る)。
# iOS 非対応 (macOS / visionOS / watchOS / tvOS only) の package も宣言 platform に合わせる。
_local_ci_swift_pkg_destination() {
  local action="$1"
  local manifest="Package.swift"
  if grep -Eq '\.iOS\(' "$manifest" 2>/dev/null; then
    if [ "$action" = "test" ]; then
      _local_ci_ios_destination_for iPhone
    else
      echo "generic/platform=iOS Simulator"
    fi
  elif grep -Eq '\.macOS\(' "$manifest" 2>/dev/null; then
    echo "platform=macOS"
  elif grep -Eq '\.visionOS\(' "$manifest" 2>/dev/null; then
    if [ "$action" = "test" ]; then
      _local_ci_ios_destination_for VisionPro
    else
      echo "generic/platform=visionOS Simulator"
    fi
  elif grep -Eq '\.watchOS\(' "$manifest" 2>/dev/null; then
    if [ "$action" = "test" ]; then
      _local_ci_ios_destination_for AppleWatch
    else
      echo "generic/platform=watchOS Simulator"
    fi
  elif grep -Eq '\.tvOS\(' "$manifest" 2>/dev/null; then
    if [ "$action" = "test" ]; then
      _local_ci_ios_destination_for AppleTV
    else
      echo "generic/platform=tvOS Simulator"
    fi
  else
    # platforms 宣言なし: SwiftData は Apple platform 専用なので macOS host build を既定にする。
    echo "platform=macOS"
  fi
}

# Package.swift を build。 swift build が SwiftData macro plugin 解決失敗で fail したら
# xcodebuild build (= package の宣言 platform に応じた destination) に fallback する。
_local_ci_swift_pkg_build() {
  local out rc
  out=$(swift build 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if ! _local_ci_swift_is_swiftdata_macro_failure "$out"; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  local scheme
  scheme=$(_local_ci_swift_pkg_resolve_scheme)
  if [ -z "$scheme" ] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "[swift] swift build が SwiftData macro 由来で fail、 xcodebuild fallback 不可 (scheme 不明 or xcodebuild なし)" >&2
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  local dest
  dest=$(_local_ci_swift_pkg_destination build)
  echo "[swift] swift build → SwiftData macro 解決不可。 xcodebuild build ($scheme, dest=$dest) に fallback" >&2
  xcodebuild build -scheme "$scheme" -destination "$dest" -quiet
}

# Package.swift を test。 swift test が SwiftData macro plugin 解決失敗で fail したら
# xcodebuild test (= package の宣言 platform に応じた destination) に fallback する。
# testTarget 宣言がなければ no-op。
_local_ci_swift_pkg_test() {
  local out rc
  out=$(swift test 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if ! _local_ci_swift_is_swiftdata_macro_failure "$out"; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  # test target の有無は manifest で判定する (= `.testTarget(..., path:)` で Tests/ 以外に
  # 置く package も拾うため、 ディレクトリ存在では判定しない — Codex review)。
  if ! grep -q '\.testTarget(' Package.swift 2>/dev/null; then
    echo "[swift] swift test 不可 (SwiftData macro)、 Package.swift に testTarget 宣言なし → test skip" >&2
    return 0
  fi
  local scheme dest
  scheme=$(_local_ci_swift_pkg_resolve_scheme)
  if [ -z "$scheme" ] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "[swift] swift test が SwiftData macro 由来で fail、 xcodebuild fallback 不可 (scheme 不明 or xcodebuild なし)" >&2
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  dest=$(_local_ci_swift_pkg_destination test)
  echo "[swift] swift test → SwiftData macro 解決不可。 xcodebuild test ($scheme, dest=$dest) に fallback" >&2
  xcodebuild test -scheme "$scheme" -destination "$dest" -quiet
}
# === /SWIFT PACKAGE BUILD STRATEGY ===

# === LOCAL HOOK EARLY SOURCE (= Codex P2-B fix) ===
# scripts/local-ci.local.sh を early source して関数 override (= ios_hook 等) を有効化。
# template 内の任意の hook 呼出より前に source されている必要があり、ここに配置。
# 後段 (ポストフック / ローカル拡張 section) では bash 実行ではなく早期 source 済 marker を
# 確認することで二重実行を避ける。
LOCAL_CI_LOCAL_SOURCED=0
if [ -f scripts/local-ci.local.sh ]; then
  # shellcheck disable=SC1091
  if source scripts/local-ci.local.sh; then
    LOCAL_CI_LOCAL_SOURCED=1
  else
    warn "scripts/local-ci.local.sh の source 失敗 (= 関数 override / 副作用 skip、template 既定で続行)"
  fi
fi
# === /LOCAL HOOK EARLY SOURCE ===

# ============================================================
# Swift (root + 一般的な monorepo 配置)
# ============================================================
SWIFT_LOCATIONS=()
if [ -f Package.swift ]; then SWIFT_LOCATIONS+=("."); fi
for d in . apps ios mobile macos packages; do
  [ -d "$d" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] && SWIFT_LOCATIONS+=("$(dirname "$p")")
  done < <(find "$d" -maxdepth 3 \( -name "Package.swift" -o -name "*.xcodeproj" -o -name "*.xcworkspace" \) 2>/dev/null)
done
# 重複除去 + .xcodeproj bundle 内部 path 除外
# (= AgentNOC.xcodeproj/project.xcworkspace が embedded されている時、find が
#    "apps/ios/AgentNOC.xcodeproj/project.xcworkspace" を返し dirname が
#    "apps/ios/AgentNOC.xcodeproj" になるため、その path は swift_dir として
#    使えない: 0 swift files + `swiftlint --strict` が exit 1 する。
#    .xcodeproj bundle は親 dir (= apps/ios) を swift_dir とすれば十分。)
SWIFT_DIRS_DEDUPED=()
for loc in "${SWIFT_LOCATIONS[@]+"${SWIFT_LOCATIONS[@]}"}"; do
  case "$loc" in
    *.xcodeproj|*.xcodeproj/*) continue ;;
  esac
  found=false
  for existing in "${SWIFT_DIRS_DEDUPED[@]+"${SWIFT_DIRS_DEDUPED[@]}"}"; do
    [ "$existing" = "$loc" ] && found=true && break
  done
  [ "$found" = "false" ] && SWIFT_DIRS_DEDUPED+=("$loc")
done

if [ ${#SWIFT_DIRS_DEDUPED[@]} -gt 0 ] && is_active "swift"; then
  if command -v swift >/dev/null 2>&1; then
    for swift_dir in "${SWIFT_DIRS_DEDUPED[@]}"; do
      label="swift"
      [ "$swift_dir" != "." ] && label="swift($swift_dir)"

      if [ -f "$swift_dir/Package.swift" ]; then
        # SwiftData macro 等で swift build/test が不可なら xcodebuild に fallback
        # (= SWIFT PACKAGE BUILD STRATEGY section)。
        run_step_in "$swift_dir" "$label build" _local_ci_swift_pkg_build
        if [ "$SKIP_TEST" = "false" ]; then
          run_step_in "$swift_dir" "$label test" _local_ci_swift_pkg_test
        fi
      else
        # Xcode project (= AGENTS.md §12 / ADR 0031) → iOS Simulator-First Testing hook
        # `ios_hook` は template 既定 = `_local_ci_ios_default_hook` への delegate、
        # project の `scripts/local-ci.local.sh` で再定義すると subset / extra flag を override 可
        if command -v xcodebuild >/dev/null 2>&1; then
          run_step_in "$swift_dir" "$label ios-hook" ios_hook
        else
          warn "$label: Xcode プロジェクト検出 ($swift_dir) だが xcodebuild なし。Xcode CLI を導入 ('xcode-select --install')"
        fi
      fi

      # swiftlint mandatory (= AGENTS.md §12.3、project config 必須)。
      # 道具 or config 不在で push abort、警告 only ではない。
      if ! command -v swiftlint >/dev/null 2>&1; then
        STEPS+=("✗ [$swift_dir] $label swiftlint: tool unavailable (= 'brew install swiftlint')")
        FAILED=1
        printf "${RED}❌ [%s] %s swiftlint: tool unavailable. brew install swiftlint${RESET}\n" "$swift_dir" "$label"
      elif [ ! -f "$swift_dir/.swiftlint.yml" ] && [ ! -f "$swift_dir/.swiftlint.yaml" ] \
        && [ ! -f .swiftlint.yml ] && [ ! -f .swiftlint.yaml ]; then
        STEPS+=("✗ [$swift_dir] $label swiftlint: .swiftlint.yml absent (= project config 必須)")
        FAILED=1
        printf "${RED}❌ [%s] %s swiftlint: .swiftlint.yml (or .yaml) が必要。dev-bootstrap templates/swiftlint.yml.template を baseline に作成してください${RESET}\n" "$swift_dir" "$label"
      else
        run_step_in "$swift_dir" "$label swiftlint" swiftlint lint --quiet --strict
      fi

      # swiftformat mandatory (= 同上)
      if ! command -v swiftformat >/dev/null 2>&1; then
        STEPS+=("✗ [$swift_dir] $label swiftformat: tool unavailable (= 'brew install swiftformat')")
        FAILED=1
        printf "${RED}❌ [%s] %s swiftformat: tool unavailable. brew install swiftformat${RESET}\n" "$swift_dir" "$label"
      elif [ ! -f "$swift_dir/.swiftformat" ] && [ ! -f .swiftformat ]; then
        STEPS+=("✗ [$swift_dir] $label swiftformat: .swiftformat absent (= project config 必須)")
        FAILED=1
        printf "${RED}❌ [%s] %s swiftformat: .swiftformat が必要。dev-bootstrap templates/swiftformat.template を baseline に作成してください${RESET}\n" "$swift_dir" "$label"
      else
        run_step_in "$swift_dir" "$label swiftformat --lint" swiftformat --lint .
      fi
    done
  else
    warn "Swift プロジェクト検出だが swift コマンドなし。Xcode CLI を導入 ('xcode-select --install')"
  fi
fi

# ============================================================
# Go
# ============================================================
if [ -f go.mod ] && is_active "go"; then
  if command -v go >/dev/null 2>&1; then
    run_step "go vet" go vet ./...
    if command -v golangci-lint >/dev/null 2>&1; then
      run_step "golangci-lint" golangci-lint run
    else
      warn "Go: golangci-lint 推奨 ('brew install golangci-lint')"
    fi
    if [ "$SKIP_TEST" = "false" ]; then
      run_step "go test" go test ./...
    fi
  else
    warn "go.mod 検出だが go コマンドなし"
  fi
fi

# ============================================================
# Gradle (Java/Kotlin)
# ============================================================
if { [ -f build.gradle ] || [ -f build.gradle.kts ]; } && is_active "gradle"; then
  if [ -x ./gradlew ]; then
    run_step "gradlew check" ./gradlew check
    if [ "$SKIP_TEST" = "false" ]; then
      run_step "gradlew test" ./gradlew test
    fi
  else
    warn "Gradle プロジェクト検出だが ./gradlew が無いか実行不可"
  fi
fi

# ============================================================
# Ruby
# ============================================================
if [ -f Gemfile ] && is_active "ruby"; then
  if command -v bundle >/dev/null 2>&1; then
    if command -v rubocop >/dev/null 2>&1; then
      run_step "rubocop" rubocop
    else
      warn "Ruby: rubocop 未インストール"
    fi
    if [ "$SKIP_TEST" = "false" ] && [ -f Rakefile ]; then
      run_step "rake test" bundle exec rake test
    fi
  else
    warn "Gemfile 検出だが bundle コマンドなし"
  fi
fi

# ============================================================
# 未対応言語の警告（git 管理対象のファイルから検出して .gitignore を尊重）
#
# 旧版は `find . -maxdepth 3 -type f -name "*.cpp" -o ...` だったが、
# find の演算子優先順位の問題で `-type f` が最初の `-name` だけにかかり
# *.cc / *.cxx ではディレクトリも含めてマッチしていた。
# また node_modules/ や target/ 配下の C++ ネイティブ拡張も拾ってしまう。
# git ls-files なら git 管理対象のみが対象なので両問題を一度に解決。
# ============================================================
_ls_files=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _ls_files="$(git ls-files 2>/dev/null)"
fi

_match_ext() {
  # $1 = pattern (e.g. '\.(cpp|cc|cxx)$'), 戻り値: マッチが1件以上あれば 0
  [ -z "$_ls_files" ] && return 1
  echo "$_ls_files" | grep -E "$1" | head -1 | grep -q .
}

if _match_ext '\.(cpp|cc|cxx|hpp|hh)$'; then
  warn "C/C++ ファイル検出だが標準対応なし — scripts/local-ci.local.sh で cmake/make を追加してください"
fi
if _match_ext '\.scala$'; then
  warn "Scala ファイル検出だが標準対応なし — scripts/local-ci.local.sh で sbt 等を追加してください"
fi
if [ -f mix.exs ] || _match_ext '\.(ex|exs)$'; then
  warn "Elixir 検出だが標準対応なし — scripts/local-ci.local.sh で mix を追加してください"
fi
if [ -f pubspec.yaml ]; then
  warn "Dart/Flutter 検出だが標準対応なし — scripts/local-ci.local.sh で flutter analyze/test を追加してください"
fi
if [ -f composer.json ]; then
  warn "PHP 検出だが標準対応なし — scripts/local-ci.local.sh で composer/phpstan を追加してください"
fi
unset _ls_files

# ============================================================
# Secrets scan (gitleaks) — 全プロジェクト共通
#
# スコープ方針:
#   1) staged 変更があれば `gitleaks protect --staged`（push 直前の検査）
#   2) なければ未 push の commit 範囲のみ `gitleaks detect --log-opts=<range>`
#      ※ 旧版の `--no-git` ワーキングツリースキャンは .gitignore を尊重せず
#         target/ や node_modules/ までスキャンして偽陽性が膨れるため廃止
#   3) 比較対象の remote ブランチが見つからない場合は警告のみ
# ============================================================
if command -v gitleaks >/dev/null 2>&1; then
  if git diff --cached --name-only 2>/dev/null | head -1 | grep -q .; then
    run_step "gitleaks (staged)" gitleaks protect --staged --no-banner
  else
    # 未 push commit の比較対象を決める
    # default branch を origin から動的取得（develop / trunk 等にも対応）
    _gl_default_branch=""
    if _gl_head="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
      _gl_default_branch="${_gl_head#refs/remotes/origin/}"
    fi

    _gl_range=""
    _gl_candidates="@{u}"
    [ -n "$_gl_default_branch" ] && _gl_candidates="$_gl_candidates origin/$_gl_default_branch"
    _gl_candidates="$_gl_candidates origin/main origin/master origin/develop origin/trunk"

    for _gl_cand in $_gl_candidates; do
      if git rev-parse --verify "$_gl_cand" >/dev/null 2>&1; then
        _gl_range="$(git rev-parse "$_gl_cand")..HEAD"
        break
      fi
    done

    if [ -n "$_gl_range" ]; then
      if git rev-list "$_gl_range" 2>/dev/null | head -1 | grep -q .; then
        run_step "gitleaks (commit range $_gl_range)" gitleaks detect --log-opts="$_gl_range" --no-banner --redact
      else
        warn "gitleaks: 未 push の新規 commit なし — スキャン対象なし（OK）"
      fi
    else
      # 比較対象 remote ブランチが見つからない (例: 初回 push の新規 branch、
      # remote 未設定の repo) ケースで silent skip すると secret が混入したまま
      # push できてしまう。fallback として HEAD 全 commit を scan する。
      # 初回 branch でも safety net を効かせる目的。
      warn "gitleaks: 比較対象の remote ブランチが見つからず — fallback で HEAD 全 commit を scan（試行: $_gl_candidates）"
      run_step "gitleaks (fallback: HEAD all commits)" gitleaks detect --no-banner --redact
    fi
    unset _gl_range _gl_cand _gl_candidates _gl_default_branch _gl_head
  fi
else
  warn "gitleaks 未インストール（推奨: brew install gitleaks）"
fi

# ============================================================
# ポストフック / ローカル拡張
# ============================================================
if [ -f scripts/local-ci.post.sh ]; then
  run_step "post-hook (scripts/local-ci.post.sh)" bash scripts/local-ci.post.sh
fi
if [ -f scripts/local-ci.local.sh ]; then
  # 既に上の "LOCAL HOOK EARLY SOURCE" で source 済 (= 関数 override + 副作用とも実行済)。
  # 二重実行を避けるため、ここでは status のみ出力 (= Codex P2-B fix)。
  if [ "${LOCAL_CI_LOCAL_SOURCED:-0}" -eq 1 ]; then
    run_step "local-hook (scripts/local-ci.local.sh, early-sourced)" true
  else
    # 早期 source が fail した場合の fallback (= 警告は既に出力済)
    run_step "local-hook (scripts/local-ci.local.sh, fallback bash)" bash scripts/local-ci.local.sh
  fi
fi

# ============================================================
# サマリ
# ============================================================
echo ""
echo "=========================================="
echo "LOCAL CI SUMMARY"
echo "=========================================="
for line in "${STEPS[@]+"${STEPS[@]}"}"; do
  case "$line" in
    "✓ "*) printf "${GREEN}%s${RESET}\n" "$line" ;;
    "✗ "*) printf "${RED}%s${RESET}\n" "$line" ;;
    *)     printf "${YELLOW}%s${RESET}\n" "$line" ;;
  esac
done

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""
  printf "${YELLOW}--- Warnings ---${RESET}\n"
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
    printf "${YELLOW}%s${RESET}\n" "$w"
  done
fi

# 実行ステップが0個の場合 → warning-only
if [ ${#STEPS[@]} -eq 0 ]; then
  echo ""
  printf "${YELLOW}⚠ 実行されたチェックが1つもありません（warning-only モード）${RESET}\n"
  printf "${YELLOW}  検出スタックがない／ツール未インストール／未対応言語のみ${RESET}\n"
  printf "${YELLOW}  push は通します（GitHub CI が最終ゲートとして実行されます）${RESET}\n"
  printf "${YELLOW}  ローカル検証を強化したい場合は scripts/local-ci.local.sh / .pre.sh を追加${RESET}\n"
  echo "=========================================="
  exit 2
fi

echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    printf "${GREEN}✅ LOCAL CI ALL GREEN${RESET} ${YELLOW}(警告 ${#WARNINGS[@]} 件 — GitHub CI で最終確認)${RESET}\n"
  else
    printf "${GREEN}✅ LOCAL CI ALL GREEN${RESET}\n"
  fi
  exit 0
else
  printf "${RED}❌ LOCAL CI FAILED — fix above and re-run${RESET}\n"
  exit 1
fi
