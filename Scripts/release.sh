#!/usr/bin/env bash
#
# fleetest のリリース(git タグ。semver)を発行するヘルパー。
#
# **タグは受け手の配布口**。受け手は install.sh / update.sh で自動的に最新のリリースタグ
# (semver 最大の X.Y.Z)へ移る(クローンの .git/config の fleetest.channel=release)。
# 発行 = 公開なので、push すると受け手の次の更新に届く(docs/releasing.md)。
# タグは v プレフィックス無しの semver(例 0.1.0)。注釈は `fleetest X.Y.Z` + 空行 + --notes-file の本文
# (update.sh の What's new と update-check.sh --notes がこれを読む)。
#
# 使い方(--notes-file は必須。引数は順不同):
#   Scripts/release.sh 0.1.0 --notes-file notes.md          # ビルド+テスト→ローカルにタグ作成(push はしない)
#   Scripts/release.sh 0.1.0 --notes-file notes.md --push   # 上記に加えて origin へ push(= 公開)
#
# 版の関係(docs/releasing.md 参照):
#   - この git タグ         = 受け手が追従する版
#   - vscode-fleetest/package.json の version = 拡張(VSIX)の版(別系統・別途 publish)
#   - Sources/FTCore/ProtocolVersion.swift   = 拡張↔CLI プロトコル版(契約非互換時のみ +1)
set -euo pipefail

VERSION=""
PUSH=0
NOTES_FILE=""

usage() {
  echo "usage: Scripts/release.sh <version> --notes-file <path> [--push]   例: Scripts/release.sh 0.1.0 --notes-file notes.md" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file) NOTES_FILE="${2:-}"; [[ -n "$NOTES_FILE" ]] || { usage; exit 1; }; shift 2 ;;
    --push) PUSH=1; shift ;;
    -*) echo "エラー: 不明なオプション: $1" >&2; usage; exit 1 ;;
    *)
      [[ -z "$VERSION" ]] || { echo "エラー: version が複数指定されています" >&2; usage; exit 1; }
      VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" || -z "$NOTES_FILE" ]]; then
  usage
  exit 1
fi
# semver 検証(v プレフィックス無し。SPM が from: で解釈できる形に限定)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "エラー: version は semver(例 0.1.0)。'v' プレフィックスは付けない" >&2
  exit 1
fi
if [[ ! -f "$NOTES_FILE" ]] || ! grep -q '[^[:space:]]' "$NOTES_FILE"; then
  echo "エラー: --notes-file が無い、または空です: $NOTES_FILE" >&2
  exit 1
fi
NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# タグは HEAD を指す。未コミットの変更を混ぜない。
if [[ -n "$(git status --porcelain)" ]]; then
  echo "エラー: 作業ツリーに未コミットの変更があります。コミットしてからリリースしてください" >&2
  exit 1
fi
if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "エラー: タグ $VERSION は既に存在します" >&2
  exit 1
fi

# 受け手は semver 最大のタグへ移る。最新以下の版を発行すると、その版は誰にも届かないか受け手を下げてしまう
LATEST="$(git tag | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/' | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ last = $0 } END { if (last != "") print last }')"
if [[ -n "$LATEST" ]]; then
  TOP="$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ last = $0 } END { print last }')"
  if [[ "$TOP" != "$VERSION" ]]; then
    echo "エラー: $VERSION は最新のリリース $LATEST より大きくありません(受け手は semver 最大のタグへ移ります)" >&2
    exit 1
  fi
fi

# リリースゲート: 配布する Swift パッケージのビルド+テスト(合否は exit code で判定)。
# テストは --parallel(CLAUDE.md「ビルド・検証」。ホストの共有資源に触るテストは
# SharedResource.<key>.locked で自分を直列化する契約なので、並列でも答えは変わらない)。
echo "==> swift build"
swift build
echo "==> swift test --parallel"
swift test --parallel

MESSAGE_FILE="$(mktemp -t fleetest-release-notes)"
trap 'rm -f "$MESSAGE_FILE"' EXIT
{ printf 'fleetest %s\n\n' "$VERSION"; cat "$NOTES_FILE"; } >"$MESSAGE_FILE"
git tag -a "$VERSION" -F "$MESSAGE_FILE"
echo "✅ タグ $VERSION を作成しました(HEAD: $(git rev-parse --short HEAD))"

if [[ "$PUSH" == "1" ]]; then
  git push origin "$VERSION"
  echo "✅ push 完了。受け手は次の install / update で $VERSION へ移ります"
else
  echo ""
  echo "ローカルにタグを作成しました(未 push)。公開するには:"
  echo "  git push origin $VERSION"
  echo "push すると受け手の次の更新で $VERSION に移ります。"
fi
