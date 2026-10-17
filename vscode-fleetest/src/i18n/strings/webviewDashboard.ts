// バッチJ 辞書(webview 側)。namespace: wvDashboard.
// 対象ソース: webview/dashboard/*.js
// webview バンドルから import される。**vscode 非依存**を保つこと。
// キーは "wvDashboard." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewDashboardStrings = {
  // main.js
  "wvDashboard.main.generatedAt": { ja: "最終更新: {time}", en: "Last updated: {time}" },
  "wvDashboard.main.projectPlaceholder": { ja: "(プロジェクトを選択)", en: "(Select a project)" },

  // render.js
  "wvDashboard.render.runCountsIncomplete": { ja: "(未完了)", en: "(Incomplete)" },
  "wvDashboard.render.headlineIncomplete": { ja: "未完了", en: "Incomplete" },
  "wvDashboard.render.none": { ja: "(なし)", en: "(None)" },
  "wvDashboard.render.anomalyHint": { ja: "配信/劣化を疑う: {breakdown}", en: "Suspect streaming/degradation first: {breakdown}" },

  // performance.js
  "wvDashboard.perf.selectedHeading": {
    ja: "選択した2件の比較: {previous} → {latest}",
    en: "Comparison of the 2 selected runs: {previous} → {latest}",
  },
  "wvDashboard.perf.selectedLoading": { ja: "比較を取得中…", en: "Fetching the comparison…" },
  "wvDashboard.perf.selectedEmpty": {
    ja: "両方で passed のシナリオがありません(比べられるのは両方に居て成功した組だけです)。",
    en: "No scenario passed in both runs (only scenarios that passed on both sides are compared).",
  },
  "wvDashboard.perf.selectedConfigDiffers": {
    ja: "profile または machine が違う2件です(デバイス構成・機械の性能の差が所要に混ざります)。",
    en: "The 2 runs differ in profile or machine (differences in devices and machine performance mix into the durations).",
  },
  "wvDashboard.perf.selectTitle": { ja: "計測の比較に使う(2件まで)", en: "Use for comparing measurements (up to 2)" },
  "wvDashboard.perf.invalidCountNote": { ja: "計測無効で除外 {count} 件", en: "{count} excluded as invalid measurements" },

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

  // deviceHealth.js
  "wvDashboard.devices.showAll": { ja: "▼ すべて表示({count} 行)", en: "▼ Show all ({count} rows)" },
  "wvDashboard.devices.showLess": { ja: "▲ 折りたたむ", en: "▲ Show less" },
  "wvDashboard.deviceHealth.stateConnected": { ja: "接続済み", en: "Connected" },
  "wvDashboard.deviceHealth.stateBooted": { ja: "起動済み(未接続)", en: "Booted (not connected)" },
  "wvDashboard.deviceHealth.stateOffline": { ja: "未起動", en: "Not started" },
  "wvDashboard.deviceHealth.stateUnknown": { ja: "不明", en: "Unknown" },
  "wvDashboard.deviceHealth.frozen": { ja: "凍結中", en: "Frozen" },
  "wvDashboard.deviceHealth.inRun": { ja: "実行中", en: "Running" },
  "wvDashboard.deviceHealth.healthWifiDisabled": { ja: "Wi-Fi 無効", en: "Wi-Fi off" },
  "wvDashboard.deviceHealth.healthClockSkew": { ja: "時計のずれ", en: "Clock skew" },
  "wvDashboard.deviceHealth.healthBlankScreen": { ja: "黒画面", en: "Blank screen" },
  "wvDashboard.deviceHealth.measuredAtTitle": { ja: "計測: {time}", en: "Measured: {time}" },
  "wvDashboard.deviceHealth.storageMeasuringCell": { ja: "測定中", en: "Measuring" },
  "wvDashboard.deviceHealth.checking": { ja: "デバイスを確認しています…", en: "Checking devices…" },
  "wvDashboard.deviceHealth.storageProgress": {
    ja: "ストレージを測定中… {done} / {total} 台",
    en: "Measuring storage… {done} / {total} devices",
  },
  "wvDashboard.deviceHealth.storageDone": { ja: "最終更新: {time}", en: "Last updated: {time}" },
  "wvDashboard.deviceHealth.storageNoTargets": {
    ja: "測れるデバイスがありません(動いている仮想デバイスだけを測る)",
    en: "Nothing to measure (only running virtual devices are measured)",
  },
  "wvDashboard.deviceHealth.storageCarriedOverTitle": {
    ja: "前回値(モニターの起動前に測った値。「ストレージ使用を更新」で測り直すまで灰色で表示)",
    en: "Previous value (measured before the monitor started; shown in gray until you click Refresh storage)",
  },
  "wvDashboard.deviceHealth.preRunTitle": { ja: "除外 / 修復", en: "Excluded / Repaired" },
  "wvDashboard.deviceHealth.cause.frozen": { ja: "画面の凍結", en: "Screen frozen" },
  "wvDashboard.deviceHealth.cause.unrecorded": { ja: "原因の記録なし", en: "Cause not recorded" },
  "wvDashboard.deviceHealth.recovery.unrecorded": { ja: "種類の記録なし", en: "Kind not recorded" },
  "wvDashboard.deviceHealth.cause.deviceGone": { ja: "デバイスが消えた", en: "Device gone" },
  "wvDashboard.deviceHealth.cause.bridgeUnreachable": { ja: "ブリッジに届かない", en: "Bridge unreachable" },
  "wvDashboard.deviceHealth.cause.bridgeTakenOver": { ja: "ブリッジが別デバイスのものに", en: "Bridge taken over" },
  "wvDashboard.deviceHealth.cause.consecutiveFailures": { ja: "連続失敗", en: "Consecutive failures" },
  "wvDashboard.deviceHealth.cause.accessibilityFault": { ja: "アクセシビリティ異常", en: "Accessibility fault" },
  "wvDashboard.deviceHealth.cause.noResponse": { ja: "応答なし", en: "No response" },
  "wvDashboard.deviceHealth.recovery.runnerRestart": { ja: "ランナーの起動し直し", en: "Runner restart" },
  "wvDashboard.deviceHealth.recovery.workerRevive": { ja: "ワーカーの復帰", en: "Worker revive" },

  // insights.js
  "wvDashboard.insights.severityCritical": { ja: "重大", en: "Critical" },
  "wvDashboard.insights.severityWarn": { ja: "警告", en: "Warning" },
  "wvDashboard.insights.severityInfo": { ja: "情報", en: "Info" },
  "wvDashboard.insights.moreCount": { ja: "他 {count} 件", en: "{count} more" },
  "wvDashboard.insights.showDevice": {
    ja: "→ デバイスの健全性で見る({worker})",
    en: "→ show in Device Health ({worker})",
  },

  // headlineDiff.js
  "wvDashboard.headlineDiff.newFailuresHeading": {
    ja: "前回(同じプロファイルの直前の実行)から新たに失敗したシナリオ",
    en: "Scenarios newly failing since the previous run (same profile)",
  },
  "wvDashboard.headlineDiff.recoveredHeading": {
    ja: "回復したシナリオ",
    en: "Scenarios recovered since the previous run",
  },

  // summaryTable.js
  "wvDashboard.summary.countText": { ja: "{total}件中{shown}件", en: "{shown} of {total}" },

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
  "wvDashboard.machineHealth.periodHeader": { ja: "集計期間（{from} - {to}）", en: "Period ({from} - {to})" },
  "wvDashboard.machineHealth.checking": { ja: "マシンを確認しています…", en: "Checking machines…" },
  "wvDashboard.machineHealth.chipText": { ja: "Text", en: "Text" },
  "wvDashboard.machineHealth.chipImage": { ja: "Image", en: "Image" },
  "wvDashboard.machineHealth.fmAlive": { ja: "alive", en: "alive" },
  "wvDashboard.machineHealth.fmDead": { ja: "dead", en: "dead" },
  "wvDashboard.machineHealth.fmUnknown": { ja: "unknown", en: "unknown" },
  "wvDashboard.machineHealth.fmCheckedAt": { ja: "確認: {time}", en: "Checked: {time}" },
  "wvDashboard.machineHealth.fmNoObservation": { ja: "モニターで観測できていません", en: "Not observed by the monitor" },
  "wvDashboard.machineHealth.visionCalls": { ja: "呼び出し {calls} · 失敗 {failures}", en: "calls {calls} · failures {failures}" },
  "wvDashboard.machineHealth.visionWindowTitle": { ja: "直近 {seconds} 秒の件数", en: "Counts over the last {seconds} s" },
  "wvDashboard.machineHealth.ocrCompiling": { ja: "コンパイル中", en: "Compiling" },
  "wvDashboard.machineHealth.ocrCompilingTitle": { ja: "OCR モデルをコンパイルしています", en: "The OCR model is compiling" },
  "wvDashboard.machineHealth.load": { ja: "CPU {cpu} · MEM {mem}", en: "CPU {cpu} · MEM {mem}" },
  "wvDashboard.machineHealth.lastRunTitle": { ja: "最後の run: {time}", en: "Last run: {time}" },
  "wvDashboard.machineHealth.lastFmDeadTitle": {
    ja: "最後の停止: {time}\n経路: {paths}",
    en: "Last dead: {time}\nPaths: {paths}",
  },
  "wvDashboard.machineHealth.lastFmDeadReason": { ja: "理由: {reason}", en: "Reason: {reason}" },
  "wvDashboard.machineHealth.fmUsageTitle": {
    ja: "再試行: {retries}(成功 {retrySuccesses})\nスキップ: {skipped}\n平均所要: {avg} ms · 最大: {max} ms\nシナリオ: {scenarios}",
    en: "Retries: {retries} (succeeded {retrySuccesses})\nSkipped: {skipped}\nAverage: {avg} ms · max: {max} ms\nScenarios: {scenarios}",
  },
  "wvDashboard.machineHealth.fmLastError": {
    ja: "最後のエラー({time} · {scenarioID}): {message}",
    en: "Last error ({time} · {scenarioID}): {message}",
  },
  "wvDashboard.machineHealth.guardTitle": {
    ja: "FM が呼び出されたがエラー等で回答できず、OCR または a11y の結果で判定が確定したステップの数 / 検証したステップの数",
    en: "Steps where FM was called but could not answer (an error or similar), so the result was settled by OCR or by the accessibility tree / steps checked",
  },
  "wvDashboard.machineHealth.guardStaleFrame": { ja: "画面の絵が古いままで確かめられなかった: {count}", en: "Could not confirm because the screenshot was stale: {count}" },
  "wvDashboard.machineHealth.gateTotalTitle": { ja: "合計: {seconds} 秒", en: "Total: {seconds} s" },
  "wvDashboard.machineHealth.pacedTitle": {
    ja: "ホスト CPU 負荷による操作前の減速。合計 {seconds} 秒",
    en: "Slowdown before actions caused by host CPU load. Total {seconds} s",
  },
  "wvDashboard.machineHealth.note.ocrBudgetExhausted": { ja: "OCR の予算切れ", en: "OCR budget exhausted" },
  "wvDashboard.machineHealth.note.ocrCompileCapped": { ja: "OCR のコンパイル待ちが上限で打ち切り", en: "OCR compile wait hit its cap" },
  "wvDashboard.machineHealth.note.ocrCompileWaited": { ja: "OCR のコンパイルを待った", en: "OCR compile waited" },
  "wvDashboard.machineHealth.note.ocrShortcutNotReady": { ja: "OCR の近道が未準備", en: "OCR shortcut not ready" },
  "wvDashboard.machineHealth.note.ocrShortcutBusy": { ja: "OCR の近道が使用中", en: "OCR shortcut busy" },
  "wvDashboard.machineHealth.note.ocrReadWhatFMMissed": { ja: "FM が読めず OCR が読めた", en: "OCR read what FM missed" },
  "wvDashboard.machineHealth.note.fmReadWhatOCRMissed": { ja: "OCR が読めず FM が読めた", en: "FM read what OCR missed" },
  "wvDashboard.machineHealth.note.fmEmptyTranscriptOnInk": { ja: "文字があるのに FM の読み取りが空", en: "FM transcript empty on visible ink" },
  "wvDashboard.machineHealth.note.visionAnomalyRetried": { ja: "Vision の異常で再試行", en: "Vision anomaly retried" },
  "wvDashboard.machineHealth.note.visionHelperRescued": { ja: "Vision ヘルパーが救済", en: "Vision helper rescued" },
  "wvDashboard.machineHealth.note.visionHelperUnavailable": { ja: "Vision ヘルパーが使えない", en: "Vision helper unavailable" },
  "wvDashboard.machineHealth.note.visionClassifierUnavailable": { ja: "Vision の分類器が使えない", en: "Vision classifier unavailable" },
  "wvDashboard.machineHealth.note.checkStateClassifierFailed": { ja: "ON/OFF 分類器が失敗", en: "Check-state classifier failed" },
} satisfies MessageDict;
