#!/usr/bin/env bash
# 保守者の作業クローンに git フックを張る(冪等)。
#
# **受け手のフローには入れない** —— 受け手は push しないのでゲートを払う理由が無く、
# install.sh / update.sh から呼ぶと導入・更新のたびに数十秒を無駄にする。
#
# フック本体は Scripts/git-hooks/ に置いて追跡してある(.git/hooks は追跡できず、
# clone し直すと黙って消えるため)。ここがやるのは core.hooksPath を張ることだけ。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

HOOKS_DIR="Scripts/git-hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "error: $HOOKS_DIR がありません" >&2
    exit 1
fi

chmod +x "$HOOKS_DIR"/* 2>/dev/null || true

current="$(git config --get core.hooksPath || true)"
if [ "$current" = "$HOOKS_DIR" ]; then
    echo "既に設定済みです: core.hooksPath=$HOOKS_DIR"
else
    if [ -n "$current" ]; then
        echo "core.hooksPath を $current から $HOOKS_DIR へ変更します"
    fi
    git config core.hooksPath "$HOOKS_DIR"
    echo "設定しました: core.hooksPath=$HOOKS_DIR"
fi

echo
echo "有効になったフック:"
for hook in "$HOOKS_DIR"/*; do
    [ -f "$hook" ] || continue
    printf "  %-12s %s\n" "$(basename "$hook")" "$([ -x "$hook" ] && echo 実行可 || echo '実行権限なし(要 chmod +x)')"
done
echo
echo "迂回: git push --no-verify / FT_SKIP_PREPUSH=1 git push"
