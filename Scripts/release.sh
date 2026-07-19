#!/usr/bin/env bash
#
# ftester の git タグ(semver)を発行するリリースヘルパー(mint 配布用)。
#
# mint 配布はこのタグを参照する:
#   受け手: mint install wave1008/foundation-tester@<version>
#           ftester init --ftester-url <github> --ftester-version <version>
# タグは SPM/mint が解釈できる semver(v プレフィックス無し。例 0.1.0)。
#
# 使い方:
#   Scripts/release.sh 0.1.0            # ビルド+テスト→ローカルにタグ作成(push はしない)
#   Scripts/release.sh 0.1.0 --push     # 上記に加えて origin へ push(= 公開)
#
# 版の関係(docs/releasing.md 参照):
#   - この git タグ         = mint が配る ftester CLI / Swift パッケージの版
#   - vscode-ftester/package.json の version = 拡張(VSIX)の版(別系統・別途 publish)
#   - Sources/FTCore/ProtocolVersion.swift   = 拡張↔CLI プロトコル版(契約非互換時のみ +1)
set -euo pipefail

VERSION="${1:-}"
PUSH="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: Scripts/release.sh <version> [--push]   例: Scripts/release.sh 0.1.0" >&2
  exit 1
fi
# semver 検証(v プレフィックス無し。SPM/mint が from: で解釈できる形に限定)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "エラー: version は semver(例 0.1.0)。'v' プレフィックスは付けない" >&2
  exit 1
fi

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

# リリースゲート: mint が配る Swift パッケージのビルド+テスト(合否は exit code で判定)。
echo "==> swift build"
swift build
echo "==> swift test"
swift test

git tag -a "$VERSION" -m "ftester $VERSION"
echo "✅ タグ $VERSION を作成しました(HEAD: $(git rev-parse --short HEAD))"

if [[ "$PUSH" == "--push" ]]; then
  git push origin "$VERSION"
  echo "✅ push 完了。受け手は: mint install wave1008/foundation-tester@$VERSION"
else
  echo ""
  echo "ローカルにタグを作成しました(未 push)。公開するには:"
  echo "  git push origin $VERSION"
  echo "受け手の導入: mint install wave1008/foundation-tester@$VERSION"
fi
