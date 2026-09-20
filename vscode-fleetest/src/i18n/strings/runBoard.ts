// 辞書(webview 側)。namespace: runBoard.
// 対象ソース: webview/monitor/runBoard.js(デバイスモニターの「run ボード」。docs/design.md §18)。
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "runBoard." 始まり。
import type { MessageDict } from "../core";

export const runBoardStrings = {
  "runBoard.title": { ja: "実行中 {count}", en: "Running {count}" },
  "runBoard.expandAll": { ja: "全て展開", en: "Expand all" },
  "runBoard.expandAllHint": {
    ja: "ON の間は、あとから始まった run も展開して表示します",
    en: "While on, runs that start later are expanded too",
  },
  "runBoard.collapse": { ja: "run ボードを閉じる", en: "Collapse run board" },
  "runBoard.expand": { ja: "run ボードを開く", en: "Expand run board" },
  "runBoard.expandLanes": { ja: "デバイスごとの内訳を開く", en: "Show per-device lanes" },
  "runBoard.collapseLanes": { ja: "デバイスごとの内訳を閉じる", en: "Hide per-device lanes" },
  "runBoard.machineIdle": { ja: "空き", en: "Free" },
  "runBoard.machineUnknown": { ja: "実行状況を観測できていません", en: "Run status not observed" },
  "runBoard.issuerRun": { ja: "{issuer} の run", en: "{issuer}'s run" },
  "runBoard.building": { ja: "ビルド中", en: "Building…" },
  "runBoard.requeued": { ja: "⟳{count}", en: "⟳{count}" },
  "runBoard.laneDropouts": { ja: "レーン離脱 {count}", en: "{count} lane(s) dropped" },
  "runBoard.preparing": { ja: "準備中(デバイスを用意しています)", en: "Preparing devices…" },
  "runBoard.laneIdle": { ja: "⏹ 待機", en: "⏹ Waiting" },
  "runBoard.remainingUnknown": { ja: "—", en: "—" },
  "runBoard.remainingTime": { ja: "残 ~{time}", en: "~{time} left" },
  "runBoard.remainingOverage": {
    ja: "残 ~0:00(+{time} 超過)",
    en: "~0:00 left (+{time} over)",
  },
} satisfies MessageDict;
