#!/usr/bin/env bash
# 更新があるかだけを答える。**取り込みは一切しない**(pull も fetch もしない)。
#
#   bash Scripts/update-check.sh                    # カレントから TOOL_ROOT を解決
#   bash Scripts/update-check.sh --tool-root <dir>  # 呼び出し側が既に知っているとき
#
# 何も変更しない(読み取りのみ)。**`git fetch` ではなく `git ls-remote` を使う** ―― fetch は
# ローカルの refs/remotes を書き換えるため、preflight.sh と同じ「読み取りのみ」を保てない。
#
# 出力は `key=value` 行(機械可読)+ 末尾の判定。判定は verdict= と終了コードの両方に出る:
#   0 = up-to-date        … 最新(または pinned。verdict= で区別する)
#   0 = pinned            … 版固定(detached HEAD)・git 管理外。更新を勧めない
#                           (ローカル変更は pinned にしない。dirty= に出すだけで判定は続ける)
#   3 = update-available  … upstream に未取得のコミットがある。取り込みは /ftester-update
#   1 = unknown           … 判定できない(オフライン・認証不可・クローン不明)。呼び出し側は黙る
#
# **`reason=` の値は言語に関わらず英語で書く**。VSCode 拡張の通知に `{reason}` としてそのまま
# 埋め込まれるため、ここを日本語にすると英語 UI の利用者に日英が混在して見える(ja UI では
# 「更新を確認できませんでした: <英語>」になる。これは承知のうえで統一している)。
# 末尾の人向けサマリ行だけは日本語(preflight.sh / install.sh と同じ扱い)。
#
# 取り込みを自動でやらないのは、更新が pull だけで終わらないため(再ビルド + 拡張の再インストール +
# プラグイン更新 + Reload Window。実体は Scripts/update.sh / スキルは /ftester-update)。加えて
# install.sh は既存クローンのローカル変更を「確認のうえ破棄」する作りで、無確認の取り込みは
# 受け手の変更を壊し得る。
#
# 契約: TOOL_ROOT の解決規則は preflight.sh / update.sh と同じ(clone 構成 = カレント / 外部構成 =
#       Package.swift の .package(path:) → 既定の隣)。片方だけ変えない。
set -uo pipefail

WORK_DIR="$PWD"
TOOL_ROOT_ARG=""
# ls-remote がネットワーク不通で張り付くのを防ぐ上限(秒)。拡張の起動時チェックから呼ばれるので
# 長くできない。超えたら unknown = 黙ってスキップ
TIMEOUT_SEC="${FTESTER_UPDATE_CHECK_TIMEOUT:-20}"

usage() {
  cat <<'EOF'
使い方: update-check.sh [--tool-root <dir>]

  --tool-root <dir>  foundation-tester クローンの場所(省略時はカレントから解決)
  -h, --help         このヘルプ

終了コード: 0=最新/対象外(verdict= で区別) / 3=更新あり / 1=判定不能
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root に値が必要です}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$1"; }
kv()  { printf '%s=%s\n' "$1" "$2"; }

# **`cmd | head` を値の取得に使わない**(pipefail 下で head が先に閉じると上流が SIGPIPE で死に、
# それを失敗として拾う)。preflight.sh の same-name ヘルパーと同じ理由
first_line() { printf '%s' "${1%%$'\n'*}"; }

finish() { # <verdict> <exit code> [reason(英語)]
  kv verdict "$1"
  [ -n "${3:-}" ] && kv reason "$3"
  say ""
  case "$1" in
    up-to-date) say "✅ 最新です。" ;;
    update-available)
      say "🆕 更新があります(ローカル ${local_head:0:8} → upstream ${remote_head:0:8})。"
      say "   取り込み → Claude Code で /ftester-update / 手動なら bash $tool_root/Scripts/update.sh"
      say "   (git pull だけでは CLI も拡張もスキルも入れ替わりません)" ;;
    pinned) say "⏭️ 更新チェックの対象外です: ${3:-}" ;;
    *) say "❔ 判定できませんでした: ${3:-}" ;;
  esac
  exit "$2"
}

kv work_dir "$WORK_DIR"

# ---- TOOL_ROOT の解決(preflight.sh と同じ規則) --------------------------------
tool_root=""
if [ -n "$TOOL_ROOT_ARG" ]; then
  [ -d "$TOOL_ROOT_ARG/Sources/FTScenarioRunner" ] \
    && tool_root="$(cd "$TOOL_ROOT_ARG" && pwd)"
elif [ -d "$WORK_DIR/Sources/FTScenarioRunner" ]; then
  tool_root="$WORK_DIR"                       # clone 構成
else                                          # 外部パッケージ構成
  declared="$(sed -n 's/.*\.package(path: *"\([^"]*\)".*/\1/p' "$WORK_DIR/Package.swift" 2>/dev/null | head -1)"
  for candidate in "$declared" "../foundation-tester"; do
    [ -n "$candidate" ] || continue
    case "$candidate" in /*) : ;; *) candidate="$WORK_DIR/$candidate" ;; esac
    if [ -d "$candidate/Sources/FTScenarioRunner" ]; then
      tool_root="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi

if [ -z "$tool_root" ]; then
  kv tool_root ""
  finish unknown 1 "no foundation-tester clone found"
fi
kv tool_root "$tool_root"

command -v git >/dev/null 2>&1 || finish unknown 1 "git is not available"
if [ ! -d "$tool_root/.git" ]; then
  finish pinned 0 "clone is not under git ($tool_root)"
fi

# ---- ローカル側の状態 ----------------------------------------------------------
branch="$(git -C "$tool_root" symbolic-ref --short -q HEAD)"
if [ -z "$branch" ]; then
  kv branch detached
  finish pinned 0 "version pinned (detached HEAD: $(git -C "$tool_root" describe --tags --always 2>/dev/null))"
fi
kv branch "$branch"

local_head="$(git -C "$tool_root" rev-parse HEAD 2>/dev/null)"
[ -n "$local_head" ] || finish unknown 1 "cannot resolve HEAD"
kv local_head "$local_head"

if [ -n "$(git -C "$tool_root" status --porcelain 2>/dev/null)" ]; then
  kv dirty yes
else
  kv dirty no
fi

# 追跡先はブランチ設定が正(fork や別リモートで origin/main とは限らない)。未設定なら origin/<branch>
remote="$(git -C "$tool_root" config --get "branch.$branch.remote")"
[ -n "$remote" ] || remote="origin"
remote_ref="$(git -C "$tool_root" config --get "branch.$branch.merge")"
[ -n "$remote_ref" ] || remote_ref="refs/heads/$branch"
kv remote "$remote"
kv remote_ref "$remote_ref"

# ---- upstream 側の HEAD(ls-remote。.git を変更しない) -------------------------
tmp="$(mktemp -t ftester-update-check 2>/dev/null)"
[ -n "$tmp" ] || finish unknown 1 "cannot create a temporary file"
trap 'rm -f "$tmp"' EXIT

# GIT_TERMINAL_PROMPT=0 / BatchMode=yes が無いと、認証を求められたときに端末の無い呼び出し元
# (VSCode 拡張)で無限に待つ
GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
  git -C "$tool_root" ls-remote "$remote" "$remote_ref" >"$tmp" 2>/dev/null &
git_pid=$!
( sleep "$TIMEOUT_SEC"; kill -TERM "$git_pid" ) >/dev/null 2>&1 &
watchdog=$!
# watchdog が git を撃つと、シェルがジョブの死亡通知("Terminated: 15")を stderr に出す。
# **wait ごと stderr を捨てる**(通知はここで刈り取られる。中括弧はサブシェルを作らないので
# git_rc はそのまま使える)
{ wait "$git_pid"; git_rc=$?; } 2>/dev/null
kill "$watchdog" >/dev/null 2>&1
wait "$watchdog" >/dev/null 2>&1

if [ "$git_rc" != "0" ]; then
  finish unknown 1 "cannot reach upstream (offline, auth required, or timed out after ${TIMEOUT_SEC}s)"
fi
remote_head="$(first_line "$(cat "$tmp")")"
remote_head="${remote_head%%$'\t'*}"
if [ -z "$remote_head" ]; then
  finish unknown 1 "$remote_ref not found on upstream"
fi
kv remote_head "$remote_head"

if [ "$remote_head" = "$local_head" ]; then
  finish up-to-date 0
fi
# upstream の HEAD がローカルにも在る場合だけ向きを判定できる。**オブジェクトの有無だけで
# 「先行」と決めない** ―― 過去の fetch/pull でオブジェクトが残っていれば、遅れていても在る。
# 祖先関係で見る: upstream が HEAD の祖先 = こちらが先行(保守者の作業ツリー)= 更新不要
if git -C "$tool_root" cat-file -e "$remote_head^{commit}" 2>/dev/null \
   && git -C "$tool_root" merge-base --is-ancestor "$remote_head" HEAD 2>/dev/null; then
  finish up-to-date 0
fi

finish update-available 3
