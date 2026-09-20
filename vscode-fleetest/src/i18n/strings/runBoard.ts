// 辞書(webview 側)。namespace: runBoard.
// 対象ソース: webview/monitor/runBoard.js(デバイスモニターの「run ボード」。docs/design.md §18)。
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "runBoard." 始まり。
import type { MessageDict } from "../core";

export const runBoardStrings = {
  "runBoard.title": { ja: "実行中 {count}", en: "Running {count}" },
  "runBoard.collapse": { ja: "run ボードを閉じる", en: "Collapse run board" },
  "runBoard.expand": { ja: "run ボードを開く", en: "Expand run board" },
  "runBoard.machineRunning": { ja: "実行中", en: "Running" },
  "runBoard.machineIdle": { ja: "空き", en: "Free" },
  "runBoard.machineUnknown": { ja: "不明", en: "Unknown" },
  "runBoard.issuerRun": { ja: "{issuer} の run", en: "{issuer}'s run" },
  "runBoard.laneIdle": { ja: "⏹ 待機", en: "⏹ Waiting" },
  "runBoard.remainingUnknown": { ja: "—", en: "—" },
  "runBoard.remainingTime": { ja: "残 ~{time}", en: "~{time} left" },
  "runBoard.remainingOverage": {
    ja: "残 ~0:00(+{time} 超過)",
    en: "~0:00 left (+{time} over)",
  },
} satisfies MessageDict;
