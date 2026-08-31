// バッチH 辞書。namespace: exploreHeal.
// 対象ソース: healReviewPanel.ts, healModel.ts, dashboardPanel.ts, dashboardModel.ts
// キーは "exploreHeal." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const exploreHealStrings = {
  // ---- 共通(複数ファイルで byte-identical に使われる文言) ----
  "exploreHeal.common.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。fleetest.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the fleetest.project setting.",
  },

  // ---- healReviewPanel.ts ----
  "exploreHeal.heal.panelTitle": {
    ja: "fleetest 自己修復の確認",
    en: "fleetest Heal Review",
  },
  "exploreHeal.heal.heading": {
    ja: "自己修復の確認",
    en: "Review Heal Fixes",
  },
  "exploreHeal.heal.intro": {
    ja: "自己修復されたセレクタがあります。修復内容をシナリオのソースに反映しますか?\n    (「変更後」と「説明」は反映前に編集できます)",
    en: 'Some selectors were healed. Apply the fixes to the scenario source?\n    (You can edit "After" and "Comment" before applying)',
  },
  "exploreHeal.heal.empty": {
    ja: "対象の候補はありません。",
    en: "No candidates.",
  },
  "exploreHeal.heal.applyButtonLabel": {
    ja: "選択した {count} 件を適用",
    en: "Apply {count} selected",
  },
  "exploreHeal.heal.closeButton": {
    ja: "閉じる",
    en: "Close",
  },
  "exploreHeal.heal.busyLabel": {
    ja: "適用中...",
    en: "Applying...",
  },
  "exploreHeal.heal.fieldBefore": {
    ja: "変更前",
    en: "Before",
  },
  "exploreHeal.heal.fieldAfter": {
    ja: "変更後",
    en: "After",
  },
  "exploreHeal.heal.fieldComment": {
    ja: "説明",
    en: "Comment",
  },
  "exploreHeal.heal.selectorWarn": {
    ja: '⚠️ 適用できません(セレクタは空にできず、「"」と改行は使えません)',
    en: "⚠️ Cannot apply (the selector can't be empty, and \" or newlines aren't allowed)",
  },
  "exploreHeal.heal.commentWarn": {
    ja: "⚠️ 適用できません(説明に改行は使えません)",
    en: "⚠️ Cannot apply (the comment can't contain newlines)",
  },
  "exploreHeal.heal.unavailableWarn": {
    ja: "⚠️ 適用できません(ソースが変更されています)",
    en: "⚠️ Cannot apply (the source has changed)",
  },
  "exploreHeal.heal.log.readFailed": {
    ja: "[fleetest] 自己修復確認: {file} を読み込めません({error})",
    en: "[fleetest] Heal review: failed to read {file} ({error})",
  },
  "exploreHeal.heal.applyResponseParseFailed": {
    ja: "apply-heal の応答を解析できませんでした(exit code: {exitCode})。出力パネル「fleetest」を確認してください。",
    en: "Failed to parse the apply-heal response (exit code: {exitCode}). Check the “fleetest” output panel.",
  },
  "exploreHeal.heal.log.applyFailed": {
    ja: "[fleetest] apply-heal の実行に失敗しました: {message}",
    en: "[fleetest] apply-heal failed: {message}",
  },
  "exploreHeal.heal.applyFailed": {
    ja: "apply-heal の実行に失敗しました: {message}",
    en: "apply-heal failed: {message}",
  },

  // ---- dashboardPanel.ts ----
  "exploreHeal.dashboard.panelTitle": {
    ja: "fleetest 結果ダッシュボード",
    en: "fleetest Results Dashboard",
  },
  "exploreHeal.dashboard.title": {
    ja: "結果ダッシュボード",
    en: "Results Dashboard",
  },
  "exploreHeal.dashboard.refreshButton": {
    ja: "更新",
    en: "Refresh",
  },
  "exploreHeal.dashboard.loading": {
    ja: "読み込み中...",
    en: "Loading...",
  },
  "exploreHeal.dashboard.empty": {
    ja: "まだ実行結果がありません。テストを実行すると、ここに集計が表示されます。",
    en: "No test results yet. Run a test to see aggregated results here.",
  },
  "exploreHeal.dashboard.fetchFailedDetail": {
    ja: "実行結果の取得に失敗しました。出力パネル「fleetest」を確認してください({detail})",
    en: "Failed to fetch results. Check the “fleetest” output panel ({detail})",
  },
  "exploreHeal.dashboard.fetchFailedError": {
    ja: "実行結果の取得に失敗しました: {error}",
    en: "Failed to fetch results: {error}",
  },
  "exploreHeal.dashboard.headingRecentRuns": {
    ja: "直近の実行",
    en: "Recent Runs",
  },
  "exploreHeal.dashboard.headingPerformance": {
    ja: "パフォーマンス(--performance run)",
    en: "Performance (--performance runs)",
  },
  "exploreHeal.dashboard.headingPerfComparison": {
    ja: "前回計測との比較",
    en: "Comparison with Previous Measurement",
  },
  "exploreHeal.dashboard.colWallClock": {
    ja: "壁時計",
    en: "Wall Clock",
  },
  "exploreHeal.dashboard.colTestTime": {
    ja: "テスト時間",
    en: "Test Time",
  },
  "exploreHeal.dashboard.colScenarioTotal": {
    ja: "シナリオ所要合計",
    en: "Scenario Total",
  },
  "exploreHeal.dashboard.colLaneCount": {
    ja: "レーン",
    en: "Lanes",
  },
  "exploreHeal.dashboard.colLaneUtilisation": {
    ja: "稼働率",
    en: "Utilisation",
  },
  "exploreHeal.dashboard.colMaxScenario": {
    ja: "最長1本",
    en: "Longest scenario",
  },
  "exploreHeal.dashboard.colScenario": {
    ja: "シナリオ",
    en: "Scenario",
  },
  "exploreHeal.dashboard.colPlatform": {
    ja: "platform",
    en: "platform",
  },
  "exploreHeal.dashboard.colPrevious": {
    ja: "前回",
    en: "Previous",
  },
  "exploreHeal.dashboard.colLatest": {
    ja: "今回",
    en: "Latest",
  },
  "exploreHeal.dashboard.perfEmpty": {
    ja: "--performance を付けた run がまだありません(記録は次回の --performance 実行から)。",
    en: "No --performance runs yet (recording starts from the next --performance run).",
  },
  "exploreHeal.dashboard.headingInsights": {
    ja: "⚠ 注意が必要な現象",
    en: "⚠ Notable Issues",
  },
  "exploreHeal.dashboard.insightsEmpty": {
    ja: "注意が必要な現象はありません ✅",
    en: "No notable issues ✅",
  },
  "exploreHeal.dashboard.headingFlaky": {
    ja: "不安定なシナリオ",
    en: "Flaky Scenarios",
  },
  "exploreHeal.dashboard.flakyEmpty": {
    ja: "不安定なシナリオはありません。",
    en: "No flaky scenarios.",
  },
  "exploreHeal.dashboard.headingSlow": {
    ja: "遅いテスト",
    en: "Slow Tests",
  },
  "exploreHeal.dashboard.slowEmpty": {
    ja: "遅いテストはありません。",
    en: "No slow tests.",
  },
  "exploreHeal.dashboard.headingMatrix": {
    ja: "シナリオ×run マトリクス",
    en: "Scenario × Run Matrix",
  },
  "exploreHeal.dashboard.headingDaily": {
    ja: "日別成功率",
    en: "Daily Success Rate",
  },
  "exploreHeal.dashboard.headingSummary": {
    ja: "シナリオ別サマリ",
    en: "Scenario Summary",
  },
  "exploreHeal.dashboard.headingDevices": {
    ja: "デバイス別集計",
    en: "Device Breakdown",
  },
  "exploreHeal.dashboard.colScenarioId": {
    ja: "シナリオID",
    en: "Scenario ID",
  },
  "exploreHeal.dashboard.colRuns": {
    ja: "実行回数",
    en: "Runs",
  },
  "exploreHeal.dashboard.colSuccessRate": {
    ja: "成功率",
    en: "Success Rate",
  },
  "exploreHeal.dashboard.colFailureRate": {
    ja: "失敗率",
    en: "Failure Rate",
  },
  "exploreHeal.dashboard.colFlakinessScore": {
    ja: "遷移スコア",
    en: "Flakiness Score",
  },
  "exploreHeal.dashboard.colRecentResults": {
    ja: "直近の結果(新→旧)",
    en: "Recent Results (New→Old)",
  },
  "exploreHeal.dashboard.colAverage": {
    ja: "平均",
    en: "Average",
  },
  "exploreHeal.dashboard.colAvgMs": {
    ja: "平均ms",
    en: "Avg ms",
  },
  "exploreHeal.dashboard.colRegressionRate": {
    ja: "悪化率",
    en: "Regression Rate",
  },
  "exploreHeal.dashboard.colSlowestScene": {
    ja: "最遅 scene",
    en: "Slowest scene",
  },
  "exploreHeal.dashboard.colLastRun": {
    ja: "最終実行",
    en: "Last Run",
  },
  "exploreHeal.dashboard.colLastResult": {
    ja: "最終結果",
    en: "Last Result",
  },
  "exploreHeal.dashboard.colDateTime": {
    ja: "日時",
    en: "Date/Time",
  },
  "exploreHeal.dashboard.colResult": {
    ja: "結果",
    en: "Result",
  },
  "exploreHeal.dashboard.closeButton": {
    ja: "閉じる",
    en: "Close",
  },
  "exploreHeal.dashboard.headingTriage": {
    ja: "失敗の仕分け",
    en: "Failure Triage",
  },
  "exploreHeal.dashboard.headingTriageNotes": {
    ja: "注記の内訳",
    en: "Note Breakdown",
  },
  "exploreHeal.dashboard.colSection": {
    ja: "フェーズ",
    en: "Section",
  },
  "exploreHeal.dashboard.colCommand": {
    ja: "コマンド",
    en: "Command",
  },
  "exploreHeal.dashboard.colFailureKind": {
    ja: "経路",
    en: "Failure Kind",
  },
  "exploreHeal.dashboard.colCount": {
    ja: "件数",
    en: "Count",
  },
  "exploreHeal.dashboard.colScenarioExamples": {
    ja: "シナリオ例",
    en: "Example Scenarios",
  },
  "exploreHeal.dashboard.colNote": {
    ja: "注記",
    en: "Note",
  },
  "exploreHeal.dashboard.triageEmpty": {
    ja: "失敗はありません。",
    en: "No failures.",
  },
  "exploreHeal.dashboard.reportNotFound": {
    ja: "レポートを開けません。他のマシンで実行された run のレポートは gitignore のため転送されず、開けません。",
    en: "Can't open the report. Reports from runs on another machine aren't transferred (they're gitignored), so they can't be opened.",
  },
  "exploreHeal.dashboard.projectSelectTitle": {
    ja: "プロジェクトを切り替える(fleetest.project を変更します)",
    en: "Switch project (changes the fleetest.project setting)",
  },
  "exploreHeal.dashboard.runDetailFetchFailed": {
    ja: "実行詳細の取得に失敗しました。出力パネル「fleetest」を確認してください({detail})",
    en: "Failed to fetch run detail. Check the “fleetest” output panel ({detail})",
  },
  "exploreHeal.dashboard.trendFetchFailed": {
    ja: "実行履歴の取得に失敗しました。出力パネル「fleetest」を確認してください({detail})",
    en: "Failed to fetch scenario history. Check the “fleetest” output panel ({detail})",
  },
} satisfies MessageDict;
