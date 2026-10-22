// バッチH 辞書。namespace: exploreHeal.
// 対象ソース: healNotice.ts, monitorDashboardController.ts, dashboardModel.ts
// キーは "exploreHeal." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const exploreHealStrings = {
  // ---- 共通(複数ファイルで byte-identical に使われる文言) ----
  "exploreHeal.common.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。fleetest.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the fleetest.project setting.",
  },

  // ---- healNotice.ts ----
  "exploreHeal.heal.notice.message": {
    ja: "自己修復で {count} 件のセレクタを直しました。直したセレクタはシナリオに書き戻されます(書き戻した結果と書き戻せなかったものは実行ログに出ます)。git の差分を確認してコミットしてください。",
    en: "Self-healing fixed {count} selector(s). The fixed selectors are written back to the scenarios (the run log lists what was written back and what could not be). Review the git diff and commit.",
  },
  "exploreHeal.heal.notice.showChanges": {
    ja: "変更を表示",
    en: "Show Changes",
  },

  // ---- ダッシュボードタブ(monitorDashboardController.ts / monitorHtml.ts renderDashboardPanel()) ----
  "exploreHeal.dashboard.panelTitle": {
    ja: "fleetest 結果ダッシュボード",
    en: "fleetest Results Dashboard",
  },
  "exploreHeal.dashboard.title": {
    ja: "テストプロジェクト",
    en: "Test Project",
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
    ja: "指定された集計期間にテスト実行結果がありません。テストを実行するか、集計期間の設定を見直してください。",
    en: "No test results in the selected period. Run a test, or choose a different period.",
  },
  "exploreHeal.dashboard.fetchFailedDetail": {
    ja: "実行結果の取得に失敗しました。出力パネル「fleetest」を確認してください({detail})",
    en: "Failed to fetch results. Check the “fleetest” output panel ({detail})",
  },
  "exploreHeal.dashboard.fetchFailedError": {
    ja: "実行結果の取得に失敗しました: {error}",
    en: "Failed to fetch results: {error}",
  },
  "exploreHeal.dashboard.headingLatestRun": {
    ja: "最新の実行",
    en: "Latest Run",
  },
  "exploreHeal.dashboard.updating": {
    ja: "更新中…",
    en: "Updating…",
  },
  "exploreHeal.dashboard.sinceSelectTitle": {
    ja: "集計期間を切り替える",
    en: "Change the aggregation period",
  },
  "exploreHeal.dashboard.sinceLabel": { ja: "集計期間", en: "Period" },
  "exploreHeal.dashboard.sinceOption5m": { ja: "直近5分", en: "Last 5 minutes" },
  "exploreHeal.dashboard.sinceOption10m": { ja: "直近10分", en: "Last 10 minutes" },
  "exploreHeal.dashboard.sinceOption1h": { ja: "直近1時間", en: "Last 1 hour" },
  "exploreHeal.dashboard.sinceOption3h": { ja: "直近3時間", en: "Last 3 hours" },
  "exploreHeal.dashboard.sinceOption8h": { ja: "直近8時間", en: "Last 8 hours" },
  "exploreHeal.dashboard.sinceOption16h": { ja: "直近16時間", en: "Last 16 hours" },
  "exploreHeal.dashboard.sinceOption1d": { ja: "直近1日", en: "Last 1 day" },
  "exploreHeal.dashboard.sinceOption2d": { ja: "直近2日", en: "Last 2 days" },
  "exploreHeal.dashboard.sinceOption3d": { ja: "直近3日", en: "Last 3 days" },
  "exploreHeal.dashboard.sinceOption7d": { ja: "直近7日", en: "Last 7 days" },
  "exploreHeal.dashboard.sinceOption30d": { ja: "直近30日", en: "Last 30 days" },
  "exploreHeal.dashboard.sinceOption90d": { ja: "直近90日", en: "Last 90 days" },
  "exploreHeal.dashboard.deviceHealthActiveOnly": { ja: "アクティブなデバイスを表示", en: "Show active devices" },
  "exploreHeal.dashboard.deviceHealthActiveOnlyTitle": {
    ja: "オンのときはデバイスモニターで未起動以外のデバイスだけを表示します(モニターに居ないデバイスも隠します)。オフのときはすべて表示します",
    en: "When on, only devices the Device Monitor shows as anything other than Not started are listed (devices the monitor does not see are hidden too). When off, all devices are listed",
  },
  "exploreHeal.dashboard.headingDevices": { ja: "デバイスの健全性", en: "Device Health" },
  "exploreHeal.dashboard.colDevice": { ja: "デバイス", en: "Device" },
  "exploreHeal.dashboard.colDeviceState": { ja: "今の状態", en: "State" },
  "exploreHeal.dashboard.colStorage": { ja: "ストレージ使用", en: "Storage used" },
  "exploreHeal.dashboard.refreshStorage": { ja: "ストレージ使用を更新", en: "Refresh storage" },
  "exploreHeal.dashboard.refreshStorageTitle": {
    ja: "動いている仮想デバイスのストレージ使用量を測り直す(自動では測り直さない)",
    en: "Remeasure storage usage of running virtual devices (never remeasured automatically)",
  },
  "exploreHeal.dashboard.colRemoved": { ja: "run から除外", en: "Excluded from Run" },
  "exploreHeal.dashboard.colRequeued": { ja: "振り直し", en: "Requeued" },
  "exploreHeal.dashboard.colPreRun": { ja: "run 前の除外・修復", en: "Pre-run Exclude/Repair" },
  "exploreHeal.dashboard.colRecovered": { ja: "回復操作", en: "Recovery" },
  "exploreHeal.dashboard.colAppCrashes": { ja: "アプリのクラッシュ", en: "App Crashes" },
  // 列見出しの説明(title)。回数は集計期間内の run の記録から数えた累計(RunResultsQuery.DeviceHealthRow)
  "exploreHeal.dashboard.colRemovedTitle": {
    ja: "run の途中で、このデバイスを使えないと判断して run から外した回数",
    en: "Times this device was taken out of a run mid-run as unusable",
  },
  "exploreHeal.dashboard.colRequeuedTitle": {
    ja: "このデバイスで走っていたシナリオの結果を取り消し、別のデバイスでやり直させた数",
    en: "Scenarios whose result on this device was discarded and rerun on another device",
  },
  "exploreHeal.dashboard.colPreRunTitle": {
    ja: "run を始める前の検査で、画面だけ止まったデバイスを除外した回数 / 直して使った回数",
    en: "Before a run: times a device with a dead screen was excluded / repaired and used",
  },
  "exploreHeal.dashboard.colRecoveredTitle": {
    ja: "run の途中で、止まりかけたデバイスを回復させる操作を実行した回数",
    en: "Recovery actions run on this device mid-run",
  },
  "exploreHeal.dashboard.colAppCrashesTitle": {
    ja: "このデバイスのシナリオで、テスト対象アプリのクラッシュを検出した数(iOS は in-app ブリッジ経由のときだけ検出)",
    en: "Scenarios on this device where an app crash was detected (on iOS, detected only through the in-app bridge)",
  },
  "exploreHeal.dashboard.colLastEventTitle": {
    ja: "左の出来事のうち最も新しい時刻",
    en: "Time of the most recent of the events to the left",
  },
  "exploreHeal.dashboard.colLastEvent": { ja: "最後の事象", en: "Last Event" },
  "exploreHeal.dashboard.devicesEmpty": { ja: "デバイスの記録がありません。", en: "No device records." },
  "exploreHeal.dashboard.headingMachines": { ja: "マシンの健全性", en: "Machine Health" },
  "exploreHeal.dashboard.colGroupMachineNow": { ja: "現在の状態", en: "Current state" },
  "exploreHeal.dashboard.colGroupMachinePeriod": { ja: "集計期間", en: "Period" },
  "exploreHeal.dashboard.colMhFm": { ja: "FM", en: "FM" },
  "exploreHeal.dashboard.colMhFmTitle": {
    ja: "Foundation Models(テキスト・画像)が生きているか。モニターの最新の観測で、観測できていない間は「不明」です(停止の理由は各チップに載せます)",
    en: "Whether Foundation Models (text and image) are alive, from the monitor's latest observation. Unknown while nothing is observed (the reason for a stop is on each chip)",
  },
  "exploreHeal.dashboard.colMhVision": { ja: "OCR・Vision", en: "OCR / Vision" },
  "exploreHeal.dashboard.colMhVisionTitle": {
    ja: "直近の窓での Vision(OCR・画像分類器)の呼び出し件数と失敗件数。OCR モデルのコンパイル中はそれも示します",
    en: "Vision (OCR and image classifier) calls and failures in the recent window. Also shows when the OCR model is compiling",
  },
  "exploreHeal.dashboard.colMhLoad": { ja: "負荷", en: "Load" },
  "exploreHeal.dashboard.colMhRuns": { ja: "実行", en: "Runs" },
  "exploreHeal.dashboard.colMhRunsTitle": {
    ja: "期間内のこのマシンの run の数(マウスを載せると最後の run の時刻)",
    en: "Runs on this machine in the period (hover for the time of the last run)",
  },
  "exploreHeal.dashboard.colMhAve": { ja: "AVE", en: "AVE" },
  "exploreHeal.dashboard.colMhAveTitle": {
    ja: "ハードウェアビデオエンコーダー(AVE = Apple Video Encoder)が使えるか。モニターの最新の観測で、観測できていない間は「不明」です(停止の理由はチップに載せます)",
    en: "Whether the hardware video encoder (AVE = Apple Video Encoder) works, from the monitor's latest observation. Unknown while nothing is observed (the reason for a stop is on the chip)",
  },
  "exploreHeal.dashboard.colMhFmDead": { ja: "FM 停止", en: "FM dead" },
  "exploreHeal.dashboard.colMhFmDeadTitle": {
    ja: "FM が停止していると記録された run の数(マウスを載せると最後の停止の時刻・経路・理由)",
    en: "Runs that recorded FM as dead (hover for the time, path and reason of the last one)",
  },
  "exploreHeal.dashboard.colMhFmFail": { ja: "FM 失敗", en: "FM failures" },
  "exploreHeal.dashboard.colMhFmFailTitle": {
    ja: "失敗数 / FM の呼び出し数。再試行で成功した呼び出しは失敗に数えない。",
    en: "Failures / FM calls. A call that succeeded on retry is not counted as a failure.",
  },
  "exploreHeal.dashboard.colMhGuard": { ja: "判定の素通り", en: "Guard skipped" },
  "exploreHeal.dashboard.colMhGuardTitle": {
    ja: "テキストの可視性検証で FM が呼び出されたがエラー等で回答できず、OCR または a11y の結果で判定が確定したステップの数 / 検証したステップの数。多いときは FM の不調を疑ってください。記録が無い間は「–」",
    en: "Steps where the text visibility check called FM but FM could not answer (an error or similar), so the result was settled by OCR or by the accessibility tree / steps checked. Many of these suggest FM is not working well. Shows – when nothing is recorded",
  },
  "exploreHeal.dashboard.colMhGate": { ja: "FM 枠待ち", en: "FM gate wait" },
  "exploreHeal.dashboard.colMhGateTitle": {
    ja: "FM の呼び出し枠を待った最長の時間(秒。マウスを載せると合計)",
    en: "Longest wait for an FM call slot, in seconds (hover for the total)",
  },
  "exploreHeal.dashboard.colMhOcrNotes": { ja: "OCR 注記", en: "OCR notes" },
  "exploreHeal.dashboard.colMhOcrNotesTitle": {
    ja: "テキストの可視性検証で、OCR(画面の文字の読み取り)に思わしくないことが起きたステップの数。時間内に読み終わらなかった・文字認識モデルの準備を待った・OCR と FM で読めた結果が食い違った、など(マウスを載せると内訳)",
    en: "Steps where something went wrong with OCR (reading text on screen) during the text visibility check: it did not finish in time, it waited for the text recognition model to get ready, OCR and FM disagreed on what they read, and so on (hover for the breakdown)",
  },
  "exploreHeal.dashboard.colMhVisionNotes": { ja: "Vision 注記", en: "Vision notes" },
  "exploreHeal.dashboard.colMhVisionNotesTitle": {
    ja: "画像の照合や ON/OFF の画像判定(Vision)で、思わしくないことが起きたステップの数。画像処理の異常を検知してやり直した・補助プロセスが使えなかった・判定に使う分類器が使えなかった、など(マウスを載せると内訳)",
    en: "Steps where something went wrong with image matching or ON/OFF image classification (Vision): an image-processing anomaly was detected and retried, the helper process was unavailable, the classifier could not be used, and so on (hover for the breakdown)",
  },
  "exploreHeal.dashboard.colMhPaced": { ja: "減速", en: "Paced" },
  "exploreHeal.dashboard.colMhPacedTitle": {
    ja: "CPU 負荷が高すぎる時に負荷抑制機構によって減速が発生した件数(マウスを載せると減速の合計秒)",
    en: "Times the load-throttling mechanism slowed things down because CPU load was too high (hover for the total seconds)",
  },
  "exploreHeal.dashboard.machinesEmpty": { ja: "マシンの記録がありません。", en: "No machine records." },
  "exploreHeal.dashboard.summaryFilterPlaceholder": { ja: "シナリオIDで絞り込み", en: "Filter by scenario ID" },
  "exploreHeal.dashboard.summaryFailuresOnlyLabel": { ja: "失敗を含むものだけ", en: "Failures only" },
  "exploreHeal.dashboard.sourceNotFound": {
    ja: "ファイルを開けません。シナリオのファイルが見つかりません(改名・削除されている可能性があります)。",
    en: "Can't open the file. The scenario file couldn't be found (it may have been renamed or removed).",
  },
  "exploreHeal.dashboard.headingRecentRuns": {
    ja: "直近の実行",
    en: "Recent Runs",
  },
  "exploreHeal.dashboard.runsFilterAll": {
    ja: "すべて",
    en: "All",
  },
  "exploreHeal.dashboard.runsFilterPerformance": {
    ja: "パフォーマンス計測のみ",
    en: "Performance runs only",
  },
  "exploreHeal.dashboard.colWallClock": {
    ja: "経過時間",
    en: "Elapsed Time",
  },
  "exploreHeal.dashboard.colTestTime": {
    ja: "テスト時間",
    en: "Test Time",
  },
  "exploreHeal.dashboard.colScenarioTotal": {
    ja: "全シナリオ合計",
    en: "All Scenarios Total",
  },
  "exploreHeal.dashboard.colLaneCount": {
    ja: "レーン数",
    en: "Lane Count",
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
    ja: "不安定なシナリオ(直近10回)",
    en: "Flaky Scenarios (last 10 runs)",
  },
  "exploreHeal.dashboard.flakyEmpty": {
    ja: "不安定なシナリオはありません。",
    en: "No flaky scenarios.",
  },
  // 見出しの「直近N回」は RunResultsQuery.recentScenarioRunsWindow と一致必須
  // (ズレても描画も集計も通るので test/slowTestsWindow.test.mjs が等号で縛る)
  "exploreHeal.dashboard.headingSlow": {
    ja: "遅いテスト(直近10回)",
    en: "Slow Tests (last 10 runs)",
  },
  "exploreHeal.dashboard.slowEmpty": {
    ja: "遅いテストはありません。",
    en: "No slow tests.",
  },
  "exploreHeal.dashboard.headingSummary": {
    ja: "シナリオ別サマリ(直近10回)",
    en: "Scenario Summary (last 10 runs)",
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
  "exploreHeal.dashboard.colLatestResult": { ja: "直近", en: "Latest" },
  "exploreHeal.dashboard.colResultHistory": { ja: "履歴(新→旧)", en: "History (New→Old)" },
  "exploreHeal.dashboard.colAverage": {
    ja: "平均",
    en: "Average",
  },
  "exploreHeal.dashboard.colAvgSec": {
    ja: "平均sec",
    en: "Avg sec",
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
  "exploreHeal.dashboard.colMachine": {
    ja: "マシン",
    en: "Machine",
  },
  "exploreHeal.dashboard.colProfile": {
    ja: "プロファイル",
    en: "Profile",
  },
  // パフォーマンス測定 / 直近の実行の表の結果列。セルは "38 / 2"(件数)なので見出しで単位を示す
  "exploreHeal.dashboard.colPassedFailed": { ja: "pass/fail", en: "pass/fail" },
  "exploreHeal.dashboard.closeButton": {
    ja: "閉じる",
    en: "Close",
  },
  "exploreHeal.dashboard.reportNotFound": {
    ja: "レポートを開けません。他のマシンで実行された run のレポートは gitignore のため転送されず、開けません。",
    en: "Can't open the report. Reports from runs on another machine aren't transferred (they're gitignored), so they can't be opened.",
  },
  "exploreHeal.dashboard.projectSelectTitle": {
    ja: "プロジェクトを切り替える(fleetest.project を変更します)",
    en: "Switch project (changes the fleetest.project setting)",
  },
  "exploreHeal.dashboard.compareFetchFailed": {
    ja: "計測の比較の取得に失敗しました。出力パネル「fleetest」を確認してください({detail})",
    en: "Failed to fetch the measurement comparison. Check the “fleetest” output panel ({detail})",
  },
  "exploreHeal.dashboard.runsCompareHint": {
    ja: "左端のチェックで2件を選ぶと計測を比較します",
    en: "Check 2 rows at the left edge to compare their measurements",
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
