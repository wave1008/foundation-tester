#!/usr/bin/env bash
#
# vscode-ftester をローカルの VSCode にビルド→パッケージ→インストールする。
#
# 背景: このマシンでは `code` CLI が PATH に通っておらず、
# 「vsce package してから手動で code --install-extension する」運用だと
# インストール自体を忘れたまま動作確認(E2E)してしまい、旧版で空振りする事故が
# 実際に起きた(2026-07-11)。package→install→到達確認を1コマンドに固定して
# 再発を防ぐ。
set -euo pipefail

# どこから呼ばれても拡張ルート(scripts/ の親)を基準に動くようにする。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${EXT_ROOT}"

VERSION="$(node -p "require('./package.json').version")"
NAME="$(node -p "require('./package.json').name")"

echo "==> ${NAME} ${VERSION} をパッケージ化します"
# vsce package。package.json の vscode:prepublish 経由で esbuild によるコンパイルも走る。
npm run package

VSIX_PATH="${EXT_ROOT}/${NAME}-${VERSION}.vsix"
if [ ! -f "${VSIX_PATH}" ]; then
  echo "エラー: ${VSIX_PATH} が生成されていません(vsce package の出力先/バージョン不一致を確認してください)" >&2
  exit 1
fi

# `code` CLI の解決: PATH にあれば優先。無ければ VSCode.app 同梱の CLI を使う
# (PATH 未設定のマシンでも動くようにするための対策)。
if command -v code >/dev/null 2>&1; then
  CODE="$(command -v code)"
elif [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
  CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
else
  echo "エラー: VSCodeのcode CLIが見つかりません" >&2
  exit 1
fi

echo "==> ${CODE} --install-extension ${VSIX_PATH}"
"${CODE}" --install-extension "${VSIX_PATH}"

# インストール漏れの再発防止のため、インストール先ディレクトリと本体ファイルの
# 存在を実際に確認する(コマンドの終了ステータスだけでは信用しない)。
INSTALL_DIR="${HOME}/.vscode/extensions/wave1008.${NAME}-${VERSION}"
if [ ! -d "${INSTALL_DIR}" ]; then
  echo "エラー: インストール先ディレクトリが見つかりません: ${INSTALL_DIR}" >&2
  exit 1
fi
if [ ! -f "${INSTALL_DIR}/dist/extension.js" ]; then
  echo "エラー: ${INSTALL_DIR}/dist/extension.js が見つかりません" >&2
  exit 1
fi

echo "✅ vscode-ftester ${VERSION} をインストールしました"
echo "⚠️  反映にはVSCodeで「Developer: Reload Window」が必要です(インストールだけでは旧版のまま動き続けます)"
echo "⚠️  モニターパネルは開き直してください(retainContextWhenHidden で古いHTMLが保持されるため)"
