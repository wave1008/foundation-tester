// 辞書。namespace: update.
// 対象ソース: updateCheck.ts(起動時の更新チェック。Scripts/update-check.sh を実行して通知)。
// キーは "update." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const updateStrings = {
  "update.notice.message": {
    ja: "ftester に更新があります。取り込むには Claude Code で /ftester-update を実行してください(git pull だけでは反映されません)。",
    en: "An ftester update is available. Run /ftester-update in Claude Code to apply it (git pull alone is not enough).",
  },
  "update.notice.howToButton": {
    ja: "手順を表示",
    en: "Show steps",
  },
  "update.notice.dismissButton": {
    ja: "この版は通知しない",
    en: "Skip this version",
  },
  "update.steps.log": {
    ja: "[ftester] 更新の取り込み: Claude Code で /ftester-update を実行してください。Claude Code を使わない場合は `bash {toolRoot}/Scripts/update.sh`(pull・ビルド・拡張・プラグインまで1コマンド)。どちらの場合も最後に VSCode で Developer: Reload Window が要ります(git pull だけでは CLI も拡張もスキルも入れ替わりません)。",
    en: "[ftester] To apply the update: run /ftester-update in Claude Code. Without Claude Code, run `bash {toolRoot}/Scripts/update.sh` (pull, build, extension, and plugin in one command). Either way, finish with Developer: Reload Window in VS Code (git pull alone replaces neither the CLI, the extension, nor the skills).",
  },
  "update.check.availableLog": {
    ja: "[ftester] 更新があります(ローカル {local} → upstream {remote})。",
    en: "[ftester] An update is available (local {local} -> upstream {remote}).",
  },
  "update.check.silentLog": {
    ja: "[ftester] 更新チェック: 通知なし({reason})。",
    en: "[ftester] Update check: nothing to report ({reason}).",
  },
  "update.check.spawnFailedLog": {
    ja: "[ftester] 更新チェックの起動に失敗しました: {error}",
    en: "[ftester] Failed to launch the update check: {error}",
  },
} satisfies MessageDict;
