// バッチJ 辞書(webview 側)。namespace: wvDashboard.
// 対象ソース: webview/dashboard/*.js
// webview バンドルから import される。**vscode 非依存**を保つこと。
// キーは "wvDashboard." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewDashboardStrings = {
  // charts.js
  "wvDashboard.chart.noRuns": { ja: "(実行なし)", en: "(No runs)" },
  "wvDashboard.chart.failedCount": { ja: " / 失敗 {count}", en: " / failed {count}" },
  "wvDashboard.chart.fullSuiteToggle": { ja: "フルスイートのみ(≥{n} シナリオ)", en: "Full suite only (≥{n} scenarios)" },

  // main.js
  "wvDashboard.main.generatedAt": { ja: "更新: {time}", en: "Updated: {time}" },
  "wvDashboard.main.projectPlaceholder": { ja: "(プロジェクトを選択)", en: "(Select a project)" },

  // render.js
  "wvDashboard.render.runCountsIncomplete": { ja: "(未完了)", en: "(Incomplete)" },
  "wvDashboard.render.headlineIncomplete": { ja: "未完了", en: "Incomplete" },
  "wvDashboard.render.none": { ja: "(なし)", en: "(None)" },
  "wvDashboard.render.anomalyHint": { ja: "配信/劣化を疑う: {breakdown}", en: "Suspect streaming/degradation first: {breakdown}" },
  "wvDashboard.render.triageSummary": {
    ja: "失敗 {totalFailed} 件(うちステップ未到達 {unreachedCount} 件)",
    en: "{totalFailed} failures ({unreachedCount} unreached before any step)",
  },

  // performance.js
  "wvDashboard.perf.wallClockLabel": { ja: "壁時計 {value}", en: "Wall clock {value}" },
  "wvDashboard.perf.testTimeLabel": { ja: "テスト時間 {value}", en: "Test time {value}" },
  "wvDashboard.perf.comparisonHeadingPair": {
    ja: "前回計測との比較: {latest} vs {target}",
    en: "Comparison with the previous measurement: {latest} vs {target}",
  },
  "wvDashboard.perf.scenarioTotalLabel": { ja: "シナリオ所要合計 {value}", en: "Scenario total {value}" },
  "wvDashboard.perf.maxScenarioLabel": { ja: "最長1本 {value}", en: "Longest scenario {value}" },
  "wvDashboard.perf.laneUtilisationLabel": { ja: "稼働率 {value}", en: "Utilisation {value}" },
  "wvDashboard.perf.invalidCountNote": { ja: "計測無効で除外 {count} 件", en: "{count} excluded as invalid measurements" },
  "wvDashboard.perf.comparisonHeadingWith": {
    ja: "前回計測との比較({target})",
    en: "Comparison with Previous Measurement ({target})",
  },

  // runDetail.js
  "wvDashboard.runDetail.title": { ja: "run 詳細: {runID}", en: "Run Detail: {runID}" },
  "wvDashboard.runDetail.loading": { ja: "読み込み中...", en: "Loading..." },
  "wvDashboard.runDetail.none": { ja: "(なし)", en: "(None)" },
  "wvDashboard.runDetail.labelStarted": { ja: "開始", en: "Started" },
  "wvDashboard.runDetail.labelFinished": { ja: "終了", en: "Finished" },
  "wvDashboard.runDetail.labelHost": { ja: "machine", en: "machine" },
  "wvDashboard.runDetail.labelProfile": { ja: "profile", en: "profile" },
  "wvDashboard.runDetail.labelTrigger": { ja: "trigger", en: "trigger" },
  "wvDashboard.runDetail.labelCounts": {
    ja: "{passed} passed / {failed} failed / {total} total",
    en: "{passed} passed / {failed} failed / {total} total",
  },
  "wvDashboard.runDetail.measurementInvalid": {
    ja: "⚠ この run の計測は無効です({reasons})",
    en: "⚠ Measurement invalid for this run ({reasons})",
  },
  "wvDashboard.runDetail.headingWorkerAnomalies": { ja: "ワーカー異常", en: "Worker Anomalies" },
  "wvDashboard.runDetail.headingDegradedWorkers": { ja: "劣化したワーカー", en: "Degraded Workers" },
  "wvDashboard.runDetail.headingFreezeRetries": { ja: "凍結による振り直し", en: "Freeze Retries" },
  "wvDashboard.runDetail.headingBlankRepairs": { ja: "blank 修復", en: "Blank Repairs" },
  "wvDashboard.runDetail.headingBlankExclusions": { ja: "blank 除外", en: "Blank Exclusions" },
  "wvDashboard.runDetail.headingScenarios": { ja: "シナリオ", en: "Scenarios" },
  "wvDashboard.runDetail.headingErrorLogs": { ja: "エラーログ", en: "Error Logs" },
  "wvDashboard.runDetail.colKind": { ja: "種別", en: "Kind" },
  "wvDashboard.runDetail.colWorker": { ja: "worker", en: "worker" },
  "wvDashboard.runDetail.colScenarioId": { ja: "シナリオID", en: "Scenario ID" },
  "wvDashboard.runDetail.colReason": { ja: "理由", en: "Reason" },
  "wvDashboard.runDetail.colResult": { ja: "結果", en: "Result" },
  "wvDashboard.runDetail.colDuration": { ja: "所要", en: "Duration" },
  "wvDashboard.runDetail.colSkipKind": { ja: "スキップ理由", en: "Skip Reason" },
  "wvDashboard.runDetail.colStep": { ja: "#", en: "#" },
  "wvDashboard.runDetail.colDescription": { ja: "説明", en: "Description" },
  "wvDashboard.runDetail.colSection": { ja: "フェーズ", en: "Section" },
  "wvDashboard.runDetail.colCommand": { ja: "コマンド", en: "Command" },
  "wvDashboard.runDetail.colFailureKind": { ja: "経路", en: "Failure Kind" },
  "wvDashboard.runDetail.colNotes": { ja: "注記", en: "Notes" },
  "wvDashboard.runDetail.colDetail": { ja: "詳細", en: "Detail" },
  "wvDashboard.runDetail.colFileLine": { ja: "ファイル:行", en: "File:Line" },
  "wvDashboard.runDetail.buttonOpenReport": { ja: "レポートを開く", en: "Open Report" },
  "wvDashboard.runDetail.buttonTrend": { ja: "実行履歴", en: "Run History" },

  // trend.js
  "wvDashboard.trend.title": { ja: "実行履歴: {scenarioID}", en: "Run History: {scenarioID}" },
  "wvDashboard.trend.loading": { ja: "読み込み中...", en: "Loading..." },
  "wvDashboard.trend.empty": { ja: "実行履歴がありません。", en: "No run history." },
  "wvDashboard.trend.colDateTime": { ja: "日時", en: "Date/Time" },
  "wvDashboard.trend.colRunId": { ja: "run", en: "run" },
  "wvDashboard.trend.colResult": { ja: "結果", en: "Result" },
  "wvDashboard.trend.colDuration": { ja: "所要", en: "Duration" },
  "wvDashboard.trend.colWorker": { ja: "worker", en: "worker" },
  "wvDashboard.trend.colHost": { ja: "machine", en: "machine" },
} satisfies MessageDict;
