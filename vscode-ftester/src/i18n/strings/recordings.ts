// 辞書(webview 側)。namespace: recordings.
// 対象ソース: webview/monitor/{recordingsTab,deviceTiles}.js
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "recordings." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const recordingsStrings = {
  "recordings.sessions.empty": { ja: "録画セッションがありません。", en: "No recording sessions." },
  "recordings.sessions.loading": { ja: "読み込み中...", en: "Loading..." },
  "recordings.sessions.passedFailed": {
    ja: "{passed} 成功 / {failed} 失敗", en: "{passed} passed / {failed} failed",
  },
  "recordings.errors.none": { ja: "エラーなし", en: "No errors" },
  "recordings.errors.filtering": { ja: "フィルター中: {label}", en: "Filtered: {label}" },
  "recordings.errors.noneFiltered": {
    ja: "選択範囲にエラーはありません", en: "No errors in the selection",
  },
  "recordings.errors.jumpTitle": { ja: "クリックで動画内の位置へジャンプ", en: "Click to jump to this position in the video" },
  // デバイスタイルの録画中バッジ(deviceTiles.js)。
  "recordings.deviceBadge": { ja: "録画", en: "REC" },
  // TEST EXPLORER 風ツリー(再生ビュー左ペイン)。
  "recordings.tree.empty": { ja: "タイムラインがありません。", en: "No timeline available." },
  "recordings.tree.sceneDefaultTitle": { ja: "シーン {n}", en: "Scene {n}" },
} satisfies MessageDict;
