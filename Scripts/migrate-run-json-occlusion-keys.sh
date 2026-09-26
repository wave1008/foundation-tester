#!/usr/bin/env bash
# 実行記録 run.json の fmSettings / setOverrides のキーを新しい名前へ書き換える(1回きりの移行)。
#   textVisualCheck → fmTextOcclusionCheck / ocrTextVisualCheck → ocrTextOcclusionCheck
# FMSettingsRecord は欄が必須なので、書き換えないと RunResultsStore が run.json ごと読めず、
# その run が LPT・fleetest results・実行履歴から落ちる。何度流しても同じ結果になる(冪等)。
#
# 使い方: Scripts/migrate-run-json-occlusion-keys.sh [ルート...]
#   ルートを省くとこのクローンの TestProjects/ を探す。results/runs/*/*/run.json だけを対象にする
set -euo pipefail

cd "$(dirname "$0")/.."
roots=("$@")
[ ${#roots[@]} -eq 0 ] && roots=("TestProjects")

total=0
migrated=0
while IFS= read -r -d '' file; do
    total=$((total + 1))
    # キーとしてだけ現れる(引用符で囲んだ完全一致)ので、値や他の欄を巻き込まない
    if grep -q -E '"(textVisualCheck|ocrTextVisualCheck)"' "$file"; then
        perl -pi -e 's/"textVisualCheck"/"fmTextOcclusionCheck"/g; s/"ocrTextVisualCheck"/"ocrTextOcclusionCheck"/g' "$file"
        migrated=$((migrated + 1))
    fi
done < <(find "${roots[@]}" -path '*/results/runs/*/run.json' -print0 2>/dev/null)

echo "run.json: ${total} scanned, ${migrated} migrated"
