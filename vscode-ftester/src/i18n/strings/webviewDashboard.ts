// バッチJ 辞書(webview 側)。namespace: wvDashboard.
// 対象ソース: webview/dashboard/*.js
// webview バンドルから import される。**vscode 非依存**を保つこと。
// キーは "wvDashboard." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewDashboardStrings = {
  // charts.js
  "wvDashboard.chart.noRuns": { ja: "(実行なし)", en: "(No runs)" },
  "wvDashboard.chart.failedCount": { ja: " / 失敗 {count}", en: " / failed {count}" },

  // main.js
  "wvDashboard.main.generatedAt": { ja: "更新: {time}", en: "Updated: {time}" },

  // render.js
  "wvDashboard.render.runCountsIncomplete": { ja: "(未完了)", en: "(Incomplete)" },
  "wvDashboard.render.headlineIncomplete": { ja: "未完了", en: "Incomplete" },
  "wvDashboard.render.none": { ja: "(なし)", en: "(None)" },
} satisfies MessageDict;
