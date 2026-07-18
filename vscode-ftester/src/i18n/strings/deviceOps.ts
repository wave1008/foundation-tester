// バッチE 辞書。namespace: deviceOps.
// 対象ソース: monitorDeviceOps.ts, residentProcesses.ts, monitorProcessManager.ts
// キーは "deviceOps." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const deviceOpsStrings = {
  "deviceOps.nameSeparator": { ja: "、", en: ", " },
  "deviceOps.nameListMore": { ja: "{shown} ほか", en: "{shown} and more" },

  "deviceOps.log.cancelBulkUpSigterm": {
    ja: "[ftester] デバイスの起動を中断します(devices-up へ SIGTERM)",
    en: "[ftester] Stopping device startup (sending SIGTERM to devices-up)",
  },
  "deviceOps.log.bulkUpQueueCancelled": {
    ja: "[ftester] キュー待ちの一括起動を取り消しました",
    en: "[ftester] Cancelled the queued bulk startup",
  },
  "deviceOps.log.devicesStartFailed": {
    ja: "[ftester] devices {kind} の起動に失敗しました: {error}",
    en: "[ftester] Failed to start devices {kind}: {error}",
  },
  "deviceOps.log.devicesRuntimeError": {
    ja: "[ftester] devices {kind} の実行でエラーが発生しました: {error}",
    en: "[ftester] An error occurred while running devices {kind}: {error}",
  },
  "deviceOps.log.devicesClosed": {
    ja: "[ftester] devices {kind} が終了しました(exit code: {exitCode})",
    en: "[ftester] devices {kind} finished (exit code: {exitCode})",
  },
  "deviceOps.log.unknownLine": {
    ja: "[{label}] 未知の形式の行を無視しました: {value}",
    en: "[{label}] Ignored a line with an unknown format: {value}",
  },
  "deviceOps.detailUnknown": { ja: "(詳細不明)", en: "(details unknown)" },
  "deviceOps.log.bulkOpFailed": {
    ja: "[ftester] {label} が失敗しました: {error}",
    en: "[ftester] {label} failed: {error}",
  },
  "deviceOps.log.devicesRestartStartFailed": {
    ja: "[ftester] devices-restart の起動に失敗しました: {error}",
    en: "[ftester] Failed to start devices-restart: {error}",
  },
  "deviceOps.log.devicesRestartFailed": {
    ja: "[ftester] devices-restart が失敗しました: {error}",
    en: "[ftester] devices-restart failed: {error}",
  },
  "deviceOps.log.devicesRestartRuntimeError": {
    ja: "[ftester] devices-restart の実行でエラーが発生しました: {error}",
    en: "[ftester] An error occurred while running devices-restart: {error}",
  },
  "deviceOps.log.devicesRestartClosed": {
    ja: "[ftester] devices-restart が終了しました(exit code: {exitCode})",
    en: "[ftester] devices-restart finished (exit code: {exitCode})",
  },
  "deviceOps.retryLabel": { ja: "(再試行 {attempt}/{max})", en: " (retry {attempt}/{max})" },
  "deviceOps.log.deviceOpFailed": {
    ja: "[ftester] device-{op}({name})が失敗しました{attemptLabel}: {message}",
    en: "[ftester] device-{op}({name}) failed{attemptLabel}: {message}",
  },
  "deviceOps.log.deviceUpRetrying": {
    ja: "[ftester] device-up({name})を再試行します({nextAttempt}/{max}、{delayMs}ms 後)",
    en: "[ftester] Retrying device-up({name}) ({nextAttempt}/{max}, after {delayMs}ms)",
  },
  "deviceOps.deviceOpFailedGeneric": { ja: "device-{op} に失敗しました。", en: "device-{op} failed." },
  "deviceOps.log.deviceOpClosed": {
    ja: "[ftester] device-{op}({name})が終了しました{attemptLabel}(exit code: {exitCode})",
    en: "[ftester] device-{op}({name}) finished{attemptLabel} (exit code: {exitCode})",
  },
  "deviceOps.processExitedWithCode": {
    ja: "プロセスが exit code {exitCode} で終了しました",
    en: "The process exited with code {exitCode}",
  },
  "deviceOps.cmdStartFailed": { ja: "{cmd} の起動に失敗しました: {error}", en: "Failed to start {cmd}: {error}" },
  "deviceOps.cmdRuntimeError": {
    ja: "{cmd} の実行でエラーが発生しました: {error}",
    en: "An error occurred while running {cmd}: {error}",
  },
  "deviceOps.cmdFailedExitCode": {
    ja: "{cmd} が失敗しました(exit code: {exitCode})",
    en: "{cmd} failed (exit code: {exitCode})",
  },
  "deviceOps.cmdParseFailed": {
    ja: "{cmd} の出力を解析できませんでした: {error}",
    en: "Failed to parse {cmd} output: {error}",
  },
  "deviceOps.cmdOutputInvalid": { ja: "{cmd} の出力形式が不正です。", en: "{cmd} output format is invalid." },
  "deviceOps.createAlreadyRunning": {
    ja: "作成処理が既に実行中です。",
    en: "A create operation is already in progress.",
  },
  "deviceOps.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the ftester.project setting.",
  },
  "deviceOps.log.createDeviceStartFailed": {
    ja: "[ftester] create-device({name})の起動に失敗しました: {error}",
    en: "[ftester] Failed to start create-device({name}): {error}",
  },
  "deviceOps.log.createDeviceFailed": {
    ja: "[ftester] create-device({name})が失敗しました: {error}",
    en: "[ftester] create-device({name}) failed: {error}",
  },
  "deviceOps.log.createDeviceRuntimeError": {
    ja: "[ftester] create-device({name})の実行でエラーが発生しました: {error}",
    en: "[ftester] An error occurred while running create-device({name}): {error}",
  },
  "deviceOps.log.createDeviceClosed": {
    ja: "[ftester] create-device({name})が終了しました(exit code: {exitCode})",
    en: "[ftester] create-device({name}) finished (exit code: {exitCode})",
  },

  "deviceOps.log.monitorStartFailed": {
    ja: "[ftester] monitor プロセスの起動に失敗しました: {error}",
    en: "[ftester] Failed to start the monitor process: {error}",
  },
  "deviceOps.monitorStartFailedMessage": {
    ja: "モニタープロセスの起動に失敗しました: {error}",
    en: "Failed to start the monitor process: {error}",
  },
  "deviceOps.log.monitorRuntimeError": {
    ja: "[ftester] monitor プロセスでエラーが発生しました: {error}",
    en: "[ftester] An error occurred in the monitor process: {error}",
  },
  "deviceOps.monitorExitedUnexpectedHint": {
    ja: "予期せず終了しました。「モニター再起動」で再開できます。",
    en: "It exited unexpectedly. You can restart it with \"Restart Monitor\".",
  },
  "deviceOps.monitorExitedMachineHint": {
    ja:
      "マシンプロファイル未設定の可能性があります。「ftester machine set」の実行、または " +
      "Projects/<project>/profiles/machines/ の内容を確認してください。",
    en:
      "The machine profile might not be configured. Run \"ftester machine set\", or check " +
      "Projects/<project>/profiles/machines/.",
  },
  "deviceOps.monitorClosedMessage": {
    ja: "モニタープロセスが終了しました(exit code: {exitCode}, signal: {signal})。{hint}",
    en: "The monitor process exited (exit code: {exitCode}, signal: {signal}). {hint}",
  },
  "deviceOps.log.hostMetricsStartFailed": {
    ja: "[host-metrics] プロセスの起動に失敗しました: {error}",
    en: "[host-metrics] Failed to start the process: {error}",
  },
  "deviceOps.log.hostMetricsRuntimeError": {
    ja: "[host-metrics] プロセスでエラーが発生しました: {error}",
    en: "[host-metrics] An error occurred in the process: {error}",
  },
  "deviceOps.log.hostMetricsGaveUp": {
    ja:
      "[host-metrics] 起動直後の異常終了が続いたため自動再起動を停止しました。" +
      "バイナリが `api host-metrics` に対応しているか確認してください" +
      "(対応後は「モニター再起動」ボタンで復帰できます)。",
    en:
      "[host-metrics] Stopped automatic restarts after repeated crashes right after startup. " +
      "Check whether the binary supports `api host-metrics` " +
      "(once it does, you can recover with the \"Restart Monitor\" button).",
  },

  "deviceOps.type.bridge": { ja: "iOSブリッジ", en: "iOS bridge" },
  "deviceOps.type.simRunner": { ja: "iOSランナー", en: "iOS runner" },
  "deviceOps.type.inappBridge": { ja: "iOS in-appブリッジ", en: "iOS in-app bridge" },
  "deviceOps.type.emulator": { ja: "Androidエミュ", en: "Android emulator" },
  "deviceOps.type.androidBridge": { ja: "Androidブリッジ", en: "Android bridge" },
  "deviceOps.type.monitor": { ja: "モニター", en: "Monitor" },
  "deviceOps.type.hostMetrics": { ja: "ホストメトリクス", en: "Host metrics" },
  "deviceOps.type.liveServe": { ja: "ライブ配信", en: "Live stream" },
  "deviceOps.type.stream": { ja: "画面ストリーム", en: "Screen stream" },
  "deviceOps.type.run": { ja: "実行(run)", en: "Run (run)" },
  "deviceOps.type.mcp": { ja: "MCPサーバ", en: "MCP server" },

  "deviceOps.parent.systemLaunchd": { ja: "launchd(システム)", en: "launchd (system)" },
  "deviceOps.parent.unknown": { ja: "(不明)", en: "(unknown)" },
  "deviceOps.parent.simulatorFallback": { ja: "シミュレータ {shortUdid}", en: "Simulator {shortUdid}" },
  "deviceOps.parent.vscodeExtHost": { ja: "VSCode拡張ホスト", en: "VSCode extension host" },
  "deviceOps.parent.androidEmulatorQemu": { ja: "Androidエミュ(qemu)", en: "Android emulator (qemu)" },
  "deviceOps.parent.simulatorLaunchdSim": { ja: "シミュレータ(launchd_sim)", en: "Simulator (launchd_sim)" },

  "deviceOps.note.emulatorInternalProcess": {
    ja: "エミュレータ内プロセス",
    en: "Process inside the emulator",
  },
} satisfies MessageDict;
