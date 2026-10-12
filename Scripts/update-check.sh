#!/usr/bin/env bash
# 更新があるかだけを答える。**取り込みは一切しない**(pull も fetch もしない)。
#
#   bash Scripts/update-check.sh                    # カレントから TOOL_ROOT を解決
#   bash Scripts/update-check.sh --tool-root <dir>  # 呼び出し側が既に知っているとき
#
# 追従先は channel= で分かれる(クローンの .git/config の fleetest.channel と HEAD から決まる):
#   release … fleetest.channel=release(外部構成の受け手の既定)。最新のリリースタグ(X.Y.Z、semver 最大)と比べる。
#             remote_head = 最新タグの指すコミット(注釈付きは peeled)。local_version = HEAD を指す X.Y.Z タグ
#   branch  … ブランチ上で channel 未設定(clone 構成の保守者・FLEETEST_REF=<branch>)。追跡ブランチの先頭と比べる
#   pinned  … detached で channel 未設定(手で checkout したもの)。更新を勧めない
#
# 何も変更しない(読み取りのみ)。**`git fetch` ではなく `git ls-remote` を使う** ―― fetch は
# ローカルの refs/remotes を書き換えるため、preflight.sh と同じ「読み取りのみ」を保てない。
#
# 出力は `key=value` 行(機械可読)+ 末尾の判定。判定は verdict= と終了コードの両方に出る:
#   0 = up-to-date        … 最新(または pinned。verdict= で区別する)
#   0 = pinned            … 版固定(detached かつ channel が release でない)・git 管理外。更新を勧めない
#                           (ローカル変更は pinned にしない。dirty= に出すだけで判定は続ける)
#   3 = update-available  … upstream に未取得のコミット(release は新しいリリース)がある。取り込みは /fleetest-update
#   1 = unknown           … 判定できない(オフライン・認証不可・クローン不明)。呼び出し側は黙る
#
# **`reason=` の値は言語に関わらず英語で書く**。VSCode 拡張の通知に `{reason}` としてそのまま
# 埋め込まれるため、ここを日本語にすると英語 UI の利用者に日英が混在して見える(ja UI では
# 「更新を確認できませんでした: <英語>」になる。これは承知のうえで統一している)。
# 末尾の人向けサマリ行だけは日本語(preflight.sh / install.sh と同じ扱い)。
#
# `--notes` は取り込み前に更新内容(ローカル版より新しい各リリースの注釈)を読むための口。クローンの .git に
# 触れないよう、一時ベアリポジトリへ注釈とコミットだけ取って読む。
#
# 取り込みを自動でやらないのは、更新が移動だけで終わらないため(再ビルド + 拡張の再インストール +
# Reload Window。実体は Scripts/update.sh / スキルは /fleetest-update)。加えて
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
TIMEOUT_SEC="${FLEETEST_UPDATE_CHECK_TIMEOUT:-20}"
NOTES=0
channel=""

usage() {
  cat <<'EOF'
Usage: update-check.sh [--tool-root <dir>] [--notes]

  --tool-root <dir>  Location of the foundation-tester clone (resolved from the current directory when omitted)
  --notes            Print the release notes (newest first) of the releases newer than this clone's version, then exit
                     (release channel only; exit 0 = printed or none / 1 = could not fetch). Does not touch the clone's .git
  -h, --help         This help

Exit codes: 0=up to date / not applicable (see verdict=) / 3=update available / 1=cannot tell
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root requires a value}"; shift 2 ;;
    --notes) NOTES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$1"; }
# --notes は注釈だけを出す(key=value を混ぜない)
kv()  { [ "$NOTES" = "1" ] || printf '%s=%s\n' "$1" "$2"; }

# 対の実装: Scripts/install.sh の latest_release_tag / semver_newer(共有する仕組みが無いので同一本文を複製。
# 片方だけ変えない。releaseTrack.test.mjs が一致を検査)。並びは semver の数値順(0.10.0 > 0.9.0)
# latest_release_tag: stdin = `git ls-remote --tags` の出力。最大の X.Y.Z を出す(無ければ空)。^{} 行は読み飛ばす
latest_release_tag() {
  awk -F'\t' '$2 ~ /^refs\/tags\/[0-9]+\.[0-9]+\.[0-9]+$/ { sub(/^refs\/tags\//, "", $2); print $2 }' \
    | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ last = $0 } END { if (last != "") print last }'
}

# $1 が $2 より新しいとき 0
semver_newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ last = $0 } END { print last }')" = "$1" ]
}

# **`cmd | head` を値の取得に使わない**(pipefail 下で head が先に閉じると上流が SIGPIPE で死に、
# それを失敗として拾う)。preflight.sh の same-name ヘルパーと同じ理由
first_line() { printf '%s' "${1%%$'\n'*}"; }

finish() { # <verdict> <exit code> [reason (English)]
  if [ "$NOTES" = "1" ]; then
    case "$1" in
      pinned) say "no release notes (${3:-})"; exit 0 ;;
      *) printf '%s\n' "${3:-cannot read release notes}" >&2; exit 1 ;;
    esac
  fi
  kv verdict "$1"
  [ -n "${3:-}" ] && kv reason "$3"
  say ""
  case "$1" in
    up-to-date) say "✅ Up to date." ;;
    update-available)
      if [ "$channel" = "release" ]; then
        say "🆕 New release ${latest_version} is available (current ${local_version:-${local_head:0:8}})."
      else
        say "🆕 An update is available (local ${local_head:0:8} → upstream ${remote_head:0:8})."
      fi
      say "   Apply it → /fleetest-update in Claude Code / manually: bash $tool_root/Scripts/update.sh"
      say "   (git pull alone does not refresh the CLI, the extension or the skills)" ;;
    pinned) say "⏭️ Not applicable for update checks: ${3:-}" ;;
    *) say "❔ Could not tell: ${3:-}" ;;
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
channel_cfg="$(git -C "$tool_root" config --get fleetest.channel 2>/dev/null || true)"
if [ "$channel_cfg" = "release" ]; then
  channel=release
elif [ -z "$branch" ]; then
  channel=pinned
else
  channel=branch
fi
kv branch "${branch:-detached}"
kv channel "$channel"
if [ "$channel" = "pinned" ]; then
  finish pinned 0 "version pinned (detached HEAD: $(git -C "$tool_root" describe --tags --always 2>/dev/null))"
fi

local_head="$(git -C "$tool_root" rev-parse HEAD 2>/dev/null)"
[ -n "$local_head" ] || finish unknown 1 "cannot resolve HEAD"
kv local_head "$local_head"

if [ -n "$(git -C "$tool_root" status --porcelain 2>/dev/null)" ]; then
  kv dirty yes
else
  kv dirty no
fi

if [ "$NOTES" = "1" ] && [ "$channel" != "release" ]; then
  finish pinned 0 "not following releases (channel=$channel)"
fi

# 追跡先はブランチ設定が正(fork や別リモートで origin/main とは限らない)。未設定なら origin/<branch>。
# release は detached なので origin
remote=""; remote_ref=""
[ -z "$branch" ] || remote="$(git -C "$tool_root" config --get "branch.$branch.remote")"
[ -n "$remote" ] || remote="origin"
kv remote "$remote"
if [ "$channel" = "branch" ]; then
  remote_ref="$(git -C "$tool_root" config --get "branch.$branch.merge")"
  [ -n "$remote_ref" ] || remote_ref="refs/heads/$branch"
  kv remote_ref "$remote_ref"
fi

# ---- upstream 側(ls-remote。.git を変更しない) --------------------------------
tmp="$(mktemp -t fleetest-update-check 2>/dev/null)"
[ -n "$tmp" ] || finish unknown 1 "cannot create a temporary file"
notes_dir=""
trap 'rm -rf "$tmp" "$notes_dir"' EXIT

# <outfile> <command...>: コマンドの stdout を outfile へ。TIMEOUT_SEC を超えたら TERM(git_rc に結果)。
# GIT_TERMINAL_PROMPT=0 / BatchMode=yes が無いと、認証を求められたときに端末の無い呼び出し元
# (VSCode 拡張)で無限に待つ
run_bounded() {
  local out="$1"; shift
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$@" >"$out" 2>/dev/null &
  git_pid=$!
  ( sleep "$TIMEOUT_SEC"; kill -TERM "$git_pid" ) >/dev/null 2>&1 &
  watchdog=$!
  # watchdog が git を撃つと、シェルがジョブの死亡通知("Terminated: 15")を stderr に出す。
  # **wait ごと stderr を捨てる**(通知はここで刈り取られる。中括弧はサブシェルを作らないので
  # git_rc はそのまま使える)
  { wait "$git_pid"; git_rc=$?; } 2>/dev/null
  kill "$watchdog" >/dev/null 2>&1
  wait "$watchdog" >/dev/null 2>&1
}

unreachable="cannot reach upstream (offline, auth required, or timed out after ${TIMEOUT_SEC}s)"

if [ "$channel" = "release" ]; then
  run_bounded "$tmp" git -C "$tool_root" ls-remote --tags "$remote"
  [ "$git_rc" = "0" ] || finish unknown 1 "$unreachable"
  latest_version="$(latest_release_tag <"$tmp")"
  [ -n "$latest_version" ] || finish unknown 1 "no release tags on upstream"
  # 注釈付きタグは `^{}` 行(peeled)がコミット。軽量タグは素の行がコミット
  remote_head="$(awk -F'\t' -v t="refs/tags/$latest_version" \
    '$2 == t "^{}" { p = $1 } $2 == t { r = $1 } END { print (p != "" ? p : r) }' "$tmp")"
  local_version="$(git -C "$tool_root" tag --points-at HEAD 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/' \
    | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ last = $0 } END { if (last != "") print last }')"
  kv local_version "$local_version"
  kv latest_version "$latest_version"
  kv remote_head "$remote_head"

  if [ "$NOTES" = "1" ]; then
    # 一時ベアリポジトリへ注釈とコミットだけ取る(クローンの .git を触らない)。ローカル版が不明なら最新だけ
    url="$(git -C "$tool_root" remote get-url "$remote" 2>/dev/null)"
    [ -n "$url" ] || finish unknown 1 "cannot resolve the URL of remote $remote"
    wanted="$(awk -F'\t' '$2 ~ /^refs\/tags\/[0-9]+\.[0-9]+\.[0-9]+$/ { sub(/^refs\/tags\//, "", $2); print $2 }' "$tmp" \
      | sort -t. -k1,1n -k2,2n -k3,3n -r)"
    refspecs=()
    selected=()
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ -n "$local_version" ]; then
        semver_newer "$t" "$local_version" || continue
      else
        [ "$t" = "$latest_version" ] || continue
      fi
      semver_newer "$t" "$latest_version" && continue
      selected+=("$t")
      refspecs+=("refs/tags/$t:refs/tags/$t")
    done <<<"$wanted"
    if [ "${#selected[@]}" = "0" ]; then
      say "no release notes (already at $local_version)"
      exit 0
    fi
    notes_dir="$(mktemp -d -t fleetest-update-notes 2>/dev/null)"
    [ -n "$notes_dir" ] || finish unknown 1 "cannot create a temporary directory"
    git init -q --bare "$notes_dir" >/dev/null 2>&1 || finish unknown 1 "cannot initialise a temporary repository"
    run_bounded "$tmp" git -C "$notes_dir" fetch -q --depth=1 --filter=tree:0 "$url" "${refspecs[@]}"
    [ "$git_rc" = "0" ] || finish unknown 1 "could not fetch the release notes ($unreachable)"
    for t in "${selected[@]}"; do
      say "## $t"
      body="$(git -C "$notes_dir" for-each-ref --format='%(contents)' "refs/tags/$t" 2>/dev/null)"
      # 1行目が `fleetest X.Y.Z` なら見出しと重複するので除く
      case "$(first_line "$body")" in "fleetest $t") body="${body#*$'\n'}" ;; esac
      body="${body#"${body%%[![:space:]]*}"}"
      say "$body"
      say ""
    done
    exit 0
  fi

  if [ "$remote_head" = "$local_head" ]; then
    finish up-to-date 0
  fi
  if [ -n "$local_version" ] && semver_newer "$local_version" "$latest_version"; then
    finish up-to-date 0
  fi
  finish update-available 3
fi

run_bounded "$tmp" git -C "$tool_root" ls-remote "$remote" "$remote_ref"
if [ "$git_rc" != "0" ]; then
  finish unknown 1 "$unreachable"
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
