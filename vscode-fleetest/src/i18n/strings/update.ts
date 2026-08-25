// 辞書。namespace: update.
// 対象ソース: updateCheck.ts(起動時の更新チェック。Scripts/update-check.sh を実行して通知)。
// キーは "update." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const updateStrings = {
  "update.notice.message": {
    ja: "fleetest に更新があります。デバイスモニターの「設定」タブから更新できます。",
    en: "An fleetest update is available. You can apply it from the Settings tab of the device monitor.",
  },
  "update.notice.openSettingsButton": {
    ja: "設定タブを開く",
    en: "Open Settings tab",
  },
  "update.notice.dismissButton": {
    ja: "この版は通知しない",
    en: "Skip this version",
  },
  "update.check.availableLog": {
    ja: "[fleetest] 更新があります(ローカル {local} → upstream {remote})。",
    en: "[fleetest] An update is available (local {local} -> upstream {remote}).",
  },
  "update.check.silentLog": {
    ja: "[fleetest] 更新チェック: 通知なし({reason})。",
    en: "[fleetest] Update check: nothing to report ({reason}).",
  },
  "update.manual.checking": {
    ja: "fleetest の更新を確認しています…",
    en: "Checking for fleetest updates...",
  },
  "update.manual.upToDate": {
    ja: "fleetest は最新です。",
    en: "fleetest is up to date.",
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
    ja: "このクローンには Scripts/update-check.sh がありません(更新チェックより前の版です)。先に /fleetest-update で更新してください。",
    en: "This clone has no Scripts/update-check.sh (it predates the update check). Update it first with /fleetest-update.",
  },
  "update.check.spawnFailedLog": {
    ja: "[fleetest] 更新チェックの起動に失敗しました: {error}",
    en: "[fleetest] Failed to launch the update check: {error}",
  },
} satisfies MessageDict;
