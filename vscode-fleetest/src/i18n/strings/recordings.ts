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
  // セッション一覧の行チップ(クリップ切り出し失敗が1件以上あるセッション)。
  "recordings.sessions.clipsFailed": { ja: "クリップ{count}件失敗", en: "{count} clip(s) failed" },
  // 同・録画そのものが取れなかったセッション(録画は始まったが使えるファイルが残らなかった)。
  // **切り出し失敗とは別物**: あちらは録れた動画から切り出せなかった、こちらは録れていない
  "recordings.sessions.sourcesFailed": {
    ja: "録画失敗{count}台", en: "recording failed on {count} device(s)",
  },
  // 実行したマシン・デバイスの表示(セッション一覧の行 / 再生ビュー)。値そのもの(マシン名・
  // デバイス名)は記録由来なので訳さない —— ここにあるのは肩書きと省略表記だけ。
  "recordings.meta.machineTitle": { ja: "実行マシン", en: "Machine" },
  "recordings.meta.deviceTitle": { ja: "実行デバイス", en: "Device" },
  // TEST EXPLORER 風ツリー(再生ビュー左ペイン)。
  "recordings.tree.empty": { ja: "タイムラインがありません。", en: "No timeline available." },
  "recordings.tree.sceneDefaultTitle": { ja: "シーン {n}", en: "Scene {n}" },
  "recordings.tree.noVideo": { ja: "録画なし", en: "No recording" },
  // 再生ビュー: 動画が1本も無いセッションを開いたときの理由表示(死んだプレイヤーの代わり)。
  "recordings.player.noVideo": {
    ja: "このセッションに再生できる録画がありません。", en: "No recordings available to play in this session.",
  },
  "recordings.player.allClipsFailed": {
    ja: "切り出しに失敗したため録画は残っていません({count}件)。",
    en: "No recordings remain because clip extraction failed ({count}).",
  },
  // 録画自体が取れなかった(ソースが空/読めない)。simctl・screenrecord 側の不調がここに出る
  "recordings.player.allSourcesFailed": {
    ja: "{count}台で録画に失敗したため、このセッションに動画はありません(録画は始まりましたが、使えるファイルが残りませんでした)。",
    en: "Recording failed on {count} device(s), so this session has no video (the recorder started but produced nothing usable).",
  },
  // 一部だけ欠落しているセッション(動画はあるが失敗もある)向けの控えめな注記。
  "recordings.player.someClipsFailed": {
    ja: "{count}件のクリップが切り出しに失敗しました", en: "{count} clip(s) failed to extract",
  },
} satisfies MessageDict;
