// バッチC 辞書。namespace: monitor.
// 対象ソース: monitorModel.ts, monitorPanel.ts, monitorHealthWatchdog.ts,
//   monitorBridgeWatchdog.ts, monitorDeviceStreamController.ts
// キーは "monitor." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const monitorStrings = {
  // ---- monitorModel.ts: deviceOpMenuItem ----
  "monitor.deviceOp.labelQueued": { ja: "待機中...", en: "Waiting..." },
  "monitor.deviceOp.labelStarting": { ja: "起動中...", en: "Starting..." },
  "monitor.deviceOp.labelStopping": { ja: "停止中...", en: "Stopping..." },
  "monitor.deviceOp.labelStart": { ja: "起動", en: "Start" },
  "monitor.deviceOp.labelStop": { ja: "停止", en: "Stop" },

  // ---- monitorModel.ts: validateNewRunProfileName / updateRunProfileInObject ----
  "monitor.runProfile.nameNoSpaces": {
    ja: "プロファイル名の前後に空白を含めることはできません。",
    en: "The profile name cannot have leading or trailing spaces.",
  },
  "monitor.runProfile.nameRequired": {
    ja: "プロファイル名を入力してください。",
    en: "Enter a profile name.",
  },
  "monitor.runProfile.nameNoSlash": {
    ja: 'プロファイル名に "/" や "\\" は使えません。',
    en: 'The profile name cannot contain "/" or "\\".',
  },
  "monitor.runProfile.nameNoDotStart": {
    ja: 'プロファイル名を "." で始めることはできません。',
    en: 'The profile name cannot start with ".".',
  },
  "monitor.runProfile.nameExists": {
    ja: "実行プロファイル「{name}」は既に存在します。",
    en: 'Run profile "{name}" already exists.',
  },
  "monitor.runProfile.invalidFormat": {
    ja: "実行プロファイルの形式が不正です。",
    en: "The run profile format is invalid.",
  },
  "monitor.runProfile.defaultTimeoutInvalid": {
    ja: "defaultTimeout は正の整数で入力してください。",
    en: "Enter defaultTimeout as a positive integer.",
  },
  "monitor.runProfile.wipeThresholdInvalid": {
    ja: "wipeDataThresholdGB は正の数(GB)で入力してください。",
    en: "Enter wipeDataThresholdGB as a positive number (GB).",
  },
  "monitor.runProfile.localeInvalid": {
    ja: "locale は ja_JP のような形式で入力してください。",
    en: "Enter locale in a format like ja_JP.",
  },

  // ---- monitorModel.ts: validateNewAppProfileName / updateAppProfileInObject ----
  "monitor.appProfile.nameNoSpaces": {
    ja: "アプリプロファイル名の前後に空白を含めることはできません。",
    en: "The app profile name cannot have leading or trailing spaces.",
  },
  "monitor.appProfile.nameRequired": {
    ja: "アプリプロファイル名を入力してください。",
    en: "Enter an app profile name.",
  },
  "monitor.appProfile.nameNoSlash": {
    ja: 'アプリプロファイル名に "/" や "\\" は使えません。',
    en: 'The app profile name cannot contain "/" or "\\".',
  },
  "monitor.appProfile.nameNoDotStart": {
    ja: 'アプリプロファイル名を "." で始めることはできません。',
    en: 'The app profile name cannot start with ".".',
  },
  "monitor.appProfile.nameExists": {
    ja: "アプリプロファイル「{name}」は既に存在します。",
    en: 'App profile "{name}" already exists.',
  },
  "monitor.appProfile.invalidFormat": {
    ja: "アプリプロファイルの形式が不正です。",
    en: "The app profile format is invalid.",
  },

  // ---- monitorModel.ts: validateNewDeviceName / updateDeviceInMachineProfile ----
  "monitor.device.nameRequired": {
    ja: "デバイス名を入力してください。",
    en: "Enter a device name.",
  },
  "monitor.validation.nameAlreadyExists": {
    ja: "「{name}」は既に存在します。",
    en: '"{name}" already exists.',
  },
  "monitor.device.notFound": {
    ja: "デバイス「{name}」が見つかりませんでした。",
    en: 'Device "{name}" was not found.',
  },
  "monitor.device.portInvalid": {
    ja: "port は 0〜65535 の整数で入力してください。",
    en: "Enter port as an integer between 0 and 65535.",
  },

  // ---- monitorModel.ts: validateNewMachineProfileName / addDevicesToMachineProfile 等 ----
  "monitor.machineProfile.nameNoSpaces": {
    ja: "マシンプロファイル名の前後に空白を含めることはできません。",
    en: "The machine profile name cannot have leading or trailing spaces.",
  },
  "monitor.machineProfile.nameRequired": {
    ja: "マシンプロファイル名を入力してください。",
    en: "Enter a machine profile name.",
  },
  "monitor.machineProfile.nameNoSlash": {
    ja: 'マシンプロファイル名に "/" や "\\" は使えません。',
    en: 'The machine profile name cannot contain "/" or "\\".',
  },
  "monitor.machineProfile.nameNoDotStart": {
    ja: 'マシンプロファイル名を "." で始めることはできません。',
    en: 'The machine profile name cannot start with ".".',
  },
  "monitor.machineProfile.nameExists": {
    ja: "マシンプロファイル「{name}」は既に存在します。",
    en: 'Machine profile "{name}" already exists.',
  },
  "monitor.machineProfile.invalidFormat": {
    ja: "マシンプロファイルの形式が不正です。",
    en: "The machine profile format is invalid.",
  },

  // ---- monitorPanel.ts ----
  "monitor.statusBar.label": {
    ja: "$(device-mobile) デバイスモニター",
    en: "$(device-mobile) Device Monitor",
  },
  "monitor.statusBar.tooltip": {
    ja: "ftester: デバイスモニターを表示",
    en: "ftester: Show device monitor",
  },
  "monitor.log.stoppingOutOfScopeDevices": {
    ja: "プロファイル切り替えに伴い監視対象外のデバイスを停止します: {names}",
    en: "Stopping devices outside the monitored scope due to profile switch: {names}",
  },
  "monitor.log.streamStallRestart": {
    ja: "キーフレーム未受信のままのためヘルパーを再起動します。",
    en: "Restarting the helper because no keyframe has been received.",
  },
  "monitor.log.codecFallbackMjpeg": {
    ja: "WebCodecs 未対応/デコード失敗のため mjpeg へフォールバックします。",
    en: "Falling back to mjpeg because WebCodecs is unsupported or decoding failed.",
  },
  "monitor.log.launchFailed": {
    ja: "起動失敗: {error}",
    en: "Launch failed: {error}",
  },
  "monitor.residentKill.confirmButton": {
    ja: "強制終了",
    en: "Force quit",
  },
  "monitor.residentKill.warningBody": {
    ja: "この workspace の ftester 常駐プロセスを停止します。\n\niOS ブリッジ/ランナー・in-app ブリッジ・モニター/ホストメトリクス/画面ストリームを停止し、Android ブリッジは am/adb で停止します。\n\niOS シミュレータと Android エミュレータ本体・MCP サーバ・他 workspace のプロセスは停止しません。一部のプロセスは自動復帰します。",
    en: "This will stop this workspace's resident ftester processes.\n\nIt stops the iOS bridge/runner, in-app bridge, monitor/host-metrics, and screen streaming, and stops the Android bridge via am/adb.\n\nIt does not stop the iOS simulator or Android emulator itself, the MCP server, or other workspaces' processes. Some processes will restart automatically.",
  },
  "monitor.log.residentKillFailed": {
    ja: "常駐プロセス(PID {pid})の終了に失敗: {error}",
    en: "Failed to terminate resident process (PID {pid}): {error}",
  },

  // ---- monitorHealthWatchdog.ts ----
  "monitor.healthWatch.issueDetected": {
    ja: "ゲストOS健全性異常を検出しました({health})。",
    en: "Detected a guest OS health issue ({health}).",
  },
  "monitor.healthWatch.wifiRepairAttempt": {
    ja: "Wi-Fi 再有効化による修復を試みます。",
    en: "Attempting repair by re-enabling Wi-Fi.",
  },
  "monitor.healthWatch.wifiRepairExecuted": {
    ja: "Wi-Fi 再有効化コマンドを実行しました。",
    en: "Ran the Wi-Fi re-enable command.",
  },
  "monitor.healthWatch.wifiRepairFailed": {
    ja: "Wi-Fi 再有効化コマンドの実行に失敗しました。",
    en: "Failed to run the Wi-Fi re-enable command.",
  },
  "monitor.healthWatch.streamRepairAttempt": {
    ja: "画面ストリームヘルパーの再起動による修復を試みます。",
    en: "Attempting repair by restarting the screen stream helper.",
  },
  "monitor.healthWatch.streamSkipToCpuFallback": {
    ja: "ストリーム未稼働のためヘルパー再起動をスキップし、CPU 描画切替へ進みます。",
    en: "Skipping helper restart since the stream is not running, proceeding to CPU rendering fallback.",
  },
  "monitor.healthWatch.cpuFallbackRestart": {
    ja: "画面凍結が解消しないため CPU 描画(swiftshader)へ切り替えて再起動します。",
    en: "Switching to CPU rendering (swiftshader) and restarting because the screen freeze has not resolved.",
  },
  "monitor.healthWatch.cpuFallbackFailed": {
    ja: "CPU 描画への切替後も画面凍結が解消しませんでした。",
    en: "The screen freeze did not resolve even after switching to CPU rendering.",
  },
  "monitor.healthWatch.restartDeferredInRun": {
    ja: "実行中のため host 再起動を保留します。",
    en: "Deferring host restart because a run is in progress.",
  },
  "monitor.healthWatch.restartAttempt": {
    ja: "デバイス再起動による修復を試みます。",
    en: "Attempting repair by restarting the device.",
  },

  // ---- monitorHealthWatchdog.ts / monitorBridgeWatchdog.ts 共通 ----
  "monitor.watchdog.giveUpAfterAttempts": {
    ja: "自動修復を{count}回試みましたが復旧しませんでした。",
    en: "Attempted automatic repair {count} times but did not recover.",
  },

  // ---- monitorBridgeWatchdog.ts ----
  "monitor.bridgeWatch.unresponsiveDetected": {
    ja: "booted が{count}回連続したためブリッジ無応答とみなします。",
    en: "Treating the bridge as unresponsive after {count} consecutive booted observations.",
  },

  // ---- monitorDeviceStreamController.ts ----
  "monitor.deviceStream.fallbackToPolling": {
    ja: "ポーリングへ戻します。",
    en: "Falling back to polling.",
  },
} satisfies MessageDict;
