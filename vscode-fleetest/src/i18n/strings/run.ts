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
    ja: "対象のテストプロジェクトを解決できませんでした。fleetest.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the fleetest.project setting.",
  },

  "run.profileRequired.message": {
    ja: "❌ 実行プロファイルが指定されていません。テストを実行する前にデバイスタブで実行プロファイルを指定して下さい。",
    en: "❌ No run profile is selected. Select one in the Devices tab before running tests.",
  },
  "run.profileRequired.openDeviceTab": { ja: "デバイスタブを開く", en: "Open Devices tab" },

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
    ja: "[fleetest] ライブ操作パネルの準備に失敗しました: {message}",
    en: "[fleetest] Failed to prepare the Live Control panel: {message}",
  },

  "run.cancelled": { ja: "実行がキャンセルされました。", en: "The run was cancelled." },
  "run.cancel.stillRunningMessage": {
    ja: "実行の後始末(終了スクリプト・ロック解放)を待っています。応答しない場合は強制終了できます。",
    en: "Waiting for the run to finish cleaning up (teardown script, lock release). You can force kill it if it's unresponsive.",
  },
  "run.cancel.forceKillButton": { ja: "強制終了", en: "Force kill" },
  "run.process.stderrTailHeader": { ja: "stderr 末尾", en: "stderr tail" },
  "run.process.abnormalExit": {
    ja: "fleetest プロセスが異常終了しました(exit code: {exitCode})。出力パネル「fleetest」を確認してください。{tail}",
    en: 'The fleetest process exited abnormally (exit code: {exitCode}). Check the "fleetest" output panel.{tail}',
  },
  "run.cli.invokeFailed": {
    ja: "fleetest CLI の実行に失敗しました({message})。出力パネル「fleetest」を確認してください。",
    en: 'Failed to run the fleetest CLI ({message}). Check the "fleetest" output panel.',
  },
  "run.result.missing": {
    ja: "実行結果イベントを受信できませんでした(振り直し等で欠落した可能性)。出力パネル「fleetest」を確認してください。",
    en: 'Could not receive the run result event (possibly lost during a requeue). Check the "fleetest" output panel.',
  },

  "run.summary.total": { ja: "⏱ トータル: {seconds}s", en: "⏱ Total: {seconds}s" },
  "run.summary.testTime": { ja: "テスト実時間: {seconds}s", en: "Test time: {seconds}s" },
  "run.summary.scenarioTotal": { ja: "シナリオ合計: {seconds}s", en: "Scenario total: {seconds}s" },

  "run.debug.multipleSelected": {
    ja: "fleetest: デバッグ実行は1件のシナリオのみ対応しています。先頭の1件のみ実行します。",
    en: "fleetest: Debug run supports only a single scenario. Running only the first one.",
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
    ja: "実行結果を受信できませんでした(セッションが異常終了した可能性があります)。出力パネル「fleetest」を確認してください。",
    en: 'Could not receive the run result (the session may have exited abnormally). Check the "fleetest" output panel.',
  },
  "run.debug.scenarioRequired": {
    ja: "fleetest: デバッグ設定に scenario の指定が必要です。",
    en: "fleetest: The debug configuration requires a scenario.",
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
    ja: "fleetest プロセスの実行でエラーが発生しました: {message}",
    en: "An error occurred while running the fleetest process: {message}",
  },

  "run.cli.spawnFailed": {
    ja: "fleetest CLI の起動に失敗しました: {error}",
    en: "Failed to launch the fleetest CLI: {error}",
  },
  "run.cli.executionError": {
    ja: "fleetest CLI の実行でエラーが発生しました: {message}",
    en: "An error occurred while running the fleetest CLI: {message}",
  },
  "run.cli.superseded": {
    ja: "同じ key の新しいリクエストに置き換えられたため破棄されました",
    en: "Discarded because a newer request with the same key replaced it",
  },
  "run.cli.parseError": {
    ja: "[fleetest] stdout を JSON として解析できませんでした: {text}",
    en: "[fleetest] Could not parse stdout as JSON: {text}",
  },
  "run.cli.liveParseError": {
    ja: "[fleetest] live: stdout を JSON として解析できませんでした: {text}",
    en: "[fleetest] live: Could not parse stdout as JSON: {text}",
  },

  "run.remoteCompat.checkSkippedLog": {
    ja: "[fleetest] リモート機の版ズレ確認に失敗したためスキップします: {message}",
    en: "[fleetest] Skipping the remote version-mismatch check because it failed: {message}",
  },
  "run.remoteCompat.dialogMessage": {
    ja: "リモートのfleetestのバージョンが本機と異なります",
    en: "The remote runners' fleetest version differs from this machine's.",
  },
  "run.remoteCompat.revisionUnpublishedNote": {
    ja: "手元の HEAD が push されていないため更新できません(先に push してください)。",
    en: "Cannot update because the local HEAD hasn't been pushed yet (push first).",
  },
  "run.remoteCompat.localDirtyNote": {
    ja: "未コミットの変更はリモートへ届きません。",
    en: "Uncommitted changes will not reach the remote.",
  },
  "run.remoteCompat.localBehindNote": {
    ja: "{names}: この機械のfleetestが古いため更新できません。Scripts/update.sh で本機を更新してください。",
    en: "{names}: Cannot update — this machine's fleetest is behind. Run Scripts/update.sh to update this machine.",
  },
  "run.remoteCompat.divergedNote": {
    ja: "{names}: リビジョンが分岐しているため更新できません。共有ランナーでのブランチ検証はできません(専用機を使用してください)。",
    en: "{names}: Cannot update — revisions have diverged. Branch verification is not possible on a shared runner (use a dedicated machine).",
  },
  "run.remoteCompat.unknownRelationNote": {
    ja: "{names}: どちらが古いか判定できないため更新できません。git fetch 後に再実行してください(多くの場合この機械が古い側です)。",
    en: "{names}: Cannot update — could not determine which side is behind. Run git fetch and try again (this machine is behind in most cases).",
  },
  "run.remoteCompat.updateAndRun": { ja: "更新して実行", en: "Update and run" },
  "run.remoteCompat.blockedMessage": {
    ja: "リモートのfleetestを更新できないため実行できません",
    en: "Cannot run: the remote runners' fleetest cannot be updated from here.",
  },
  "run.remoteCompat.cancelledLog": {
    ja: "リモート機の版ズレ確認でキャンセルされたため実行を中止しました。",
    en: "The run was cancelled at the remote version-mismatch confirmation.",
  },
  "run.remoteCompat.alignProgressTitle": {
    ja: "リモート機を更新しています…",
    en: "Updating remote machines…",
  },
  "run.remoteCompat.alignProgressHost": { ja: "{name} を更新中…", en: "Updating {name}…" },
  "run.remoteCompat.alignFailed": {
    ja: "{name} の更新に失敗しました(exit {exitCode})。出力パネル「fleetest」を確認してください。",
    en: 'Failed to update {name} (exit {exitCode}). Check the "fleetest" output panel.',
  },
  "run.remoteCompat.hostUnreachable": { ja: "到達不可", en: "unreachable" },
  "run.remoteCompat.hostRevisionUnknown": { ja: "revision 不明", en: "unknown revision" },
  "run.remoteCompat.hostToolchainMismatch": {
    ja: "toolchain 不一致 ({toolchain})",
    en: "toolchain mismatch ({toolchain})",
  },
} satisfies MessageDict;
