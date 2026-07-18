// バッチF 辞書。namespace: run.
// 対象ソース: runHandler.ts, runReducer.ts, debugAdapter.ts, runLaneModel.ts, cli.ts,
//   oneShotCli.ts, debugConfig.ts, runEventBus.ts
// キーは "run." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
//
// runReducer.ts / runLaneModel.ts は webview からも import される(browser バンドルに vscode
// 依存が混入するため i18n import 禁止)。ここに定義していても両ファイルからは参照しない。
import type { MessageDict } from "../core";

export const runStrings = {
  "run.profile.failedOnly": { ja: "失敗のみ実行", en: "Run failed only" },
  "run.profile.run": { ja: "実行", en: "Run" },
  "run.profile.dryRun": { ja: "実行 (dry-run)", en: "Run (dry-run)" },
  "run.profile.debug": { ja: "デバッグ", en: "Debug" },

  "run.copy.notFound": {
    ja: "コピー対象を特定できませんでした(Test Explorer で右クリック → 名前をコピー)",
    en: "Could not determine what to copy (right-click in Test Explorer → Copy Name).",
  },
  "run.copy.copied": { ja: "コピーしました: {text}", en: "Copied: {text}" },

  "run.report.openLink": { ja: "レポートを開く", en: "Open report" },
  "run.report.notFoundFor": {
    ja: "レポートが見つかりません: {scenarioId}",
    en: "Report not found: {scenarioId}",
  },
  "run.report.notFound": { ja: "レポートが見つかりません。", en: "No report found." },
  "run.report.pickPlaceholder": { ja: "開くレポートを選択", en: "Select a report to open" },

  "run.project.unresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。",
    en: "Could not resolve the target test project.",
  },
  "run.project.unresolvedHint": {
    ja: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the ftester.project setting.",
  },

  "run.label.all": { ja: "全体", en: "All" },

  "run.log.rerunFailedSummary": {
    ja: "[rerunFailed] project={project} 展開={expanded}件 失敗記録={failedCount}件 対象={target}件",
    en: "[rerunFailed] project={project} expanded={expanded} failedRecorded={failedCount} target={target}",
  },

  "run.noFailedScenarios": {
    ja: "前回失敗したシナリオはありません(全て成功済みか未実行)",
    en: "No previously failed scenarios (all passed or not yet run).",
  },

  "run.live.preparing": {
    ja: "ライブ操作パネルのデバイス準備(未起動なら起動)と画面同期を待機しています…",
    en: "Preparing the device in the Live Control panel (launching if needed) and waiting for screen sync…",
  },
  "run.live.prepareFailed": {
    ja: "[ftester] ライブ操作パネルの準備に失敗しました: {message}",
    en: "[ftester] Failed to prepare the Live Control panel: {message}",
  },

  "run.cancelled": { ja: "実行がキャンセルされました。", en: "The run was cancelled." },
  "run.process.stderrTailHeader": { ja: "stderr 末尾", en: "stderr tail" },
  "run.process.abnormalExit": {
    ja: "ftester プロセスが異常終了しました(exit code: {exitCode})。出力パネル「ftester」を確認してください。{tail}",
    en: 'The ftester process exited abnormally (exit code: {exitCode}). Check the "ftester" output panel.{tail}',
  },
  "run.cli.invokeFailed": {
    ja: "ftester CLI の実行に失敗しました({message})。出力パネル「ftester」を確認してください。",
    en: 'Failed to run the ftester CLI ({message}). Check the "ftester" output panel.',
  },
  "run.result.missing": {
    ja: "実行結果イベントを受信できませんでした(振り直し等で欠落した可能性)。出力パネル「ftester」を確認してください。",
    en: 'Could not receive the run result event (possibly lost during a requeue). Check the "ftester" output panel.',
  },

  "run.summary.total": { ja: "⏱ トータル: {seconds}s", en: "⏱ Total: {seconds}s" },
  "run.summary.testTime": { ja: "テスト実時間: {seconds}s", en: "Test time: {seconds}s" },
  "run.summary.scenarioTotal": { ja: "シナリオ合計: {seconds}s", en: "Scenario total: {seconds}s" },

  "run.debug.multipleSelected": {
    ja: "ftester: デバッグ実行は1件のシナリオのみ対応しています。先頭の1件のみ実行します。",
    en: "ftester: Debug run supports only a single scenario. Running only the first one.",
  },
  "run.debug.sessionStartFailed": {
    ja: "デバッグセッションを開始できませんでした。",
    en: "Could not start the debug session.",
  },
  "run.debug.scenarioFailed": { ja: "シナリオが失敗しました", en: "The scenario failed." },
  "run.debug.scenarioFailedWithReport": {
    ja: "シナリオが失敗しました — レポート: {reportPath}",
    en: "The scenario failed — report: {reportPath}",
  },
  "run.debug.resultMissing": {
    ja: "実行結果を受信できませんでした(セッションが異常終了した可能性があります)。出力パネル「ftester」を確認してください。",
    en: 'Could not receive the run result (the session may have exited abnormally). Check the "ftester" output panel.',
  },
  "run.debug.scenarioRequired": {
    ja: "ftester: デバッグ設定に scenario の指定が必要です。",
    en: "ftester: The debug configuration requires a scenario.",
  },

  "run.debug.stepScopeName": { ja: "ステップ", en: "Step" },
  "run.debug.varScenario": { ja: "シナリオ", en: "Scenario" },
  "run.debug.varStepIndex": { ja: "ステップ番号", en: "Step number" },
  "run.debug.varCommand": { ja: "コマンド", en: "Command" },
  "run.debug.varSection": { ja: "区分", en: "Section" },
  "run.debug.varPosition": { ja: "位置", en: "Position" },

  "run.debug.stdinWriteFailed": {
    ja: "stdin への書き込みに失敗しました: {error}",
    en: "Failed to write to stdin: {error}",
  },
  "run.debug.noLaunchArgs": {
    ja: "launch 引数が無いまま configurationDone を受信しました",
    en: "Received configurationDone without launch arguments",
  },
  "run.debug.processError": {
    ja: "ftester プロセスの実行でエラーが発生しました: {message}",
    en: "An error occurred while running the ftester process: {message}",
  },

  "run.cli.spawnFailed": {
    ja: "ftester CLI の起動に失敗しました: {error}",
    en: "Failed to launch the ftester CLI: {error}",
  },
  "run.cli.executionError": {
    ja: "ftester CLI の実行でエラーが発生しました: {message}",
    en: "An error occurred while running the ftester CLI: {message}",
  },
  "run.cli.superseded": {
    ja: "同じ key の新しいリクエストに置き換えられたため破棄されました",
    en: "Discarded because a newer request with the same key replaced it",
  },
  "run.cli.parseError": {
    ja: "[ftester] stdout を JSON として解析できませんでした: {text}",
    en: "[ftester] Could not parse stdout as JSON: {text}",
  },
  "run.cli.liveParseError": {
    ja: "[ftester] live: stdout を JSON として解析できませんでした: {text}",
    en: "[ftester] live: Could not parse stdout as JSON: {text}",
  },
} satisfies MessageDict;
