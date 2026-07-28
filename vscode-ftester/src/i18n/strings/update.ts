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
  "update.manual.checking": {
    ja: "ftester の更新を確認しています…",
    en: "Checking for ftester updates...",
  },
  "update.manual.upToDate": {
    ja: "ftester は最新です。",
    en: "ftester is up to date.",
  },
  // {reason} は update-check.sh の reason= がそのまま入る。**あちらは ja/en どちらでも英語**
  // (スクリプト冒頭の契約)。訳すのは枠の文だけ。
  "update.manual.pinned": {
    ja: "更新チェックの対象外です: {reason}",
    en: "This clone is out of scope for update checks: {reason}",
  },
  "update.manual.unknown": {
    ja: "更新を確認できませんでした: {reason}",
    en: "Could not check for updates: {reason}",
  },
  "update.manual.noToolRoot": {
    ja: "foundation-tester のクローンが見つかりません(未導入か、既定の場所にありません)。",
    en: "No foundation-tester clone was found (not installed, or not in the expected location).",
  },
  "update.manual.noScript": {
    ja: "このクローンには Scripts/update-check.sh がありません(更新チェックより前の版です)。先に /ftester-update で更新してください。",
    en: "This clone has no Scripts/update-check.sh (it predates the update check). Update it first with /ftester-update.",
  },
  "update.check.spawnFailedLog": {
    ja: "[ftester] 更新チェックの起動に失敗しました: {error}",
    en: "[ftester] Failed to launch the update check: {error}",
  },
} satisfies MessageDict;
