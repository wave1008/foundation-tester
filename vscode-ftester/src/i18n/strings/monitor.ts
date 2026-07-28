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
  "monitor.runProfile.nameNoAtStart": {
    ja: 'プロファイル名を "@" で始めることはできません(予約されています)。',
    en: 'The profile name cannot start with "@" (reserved).',
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
  "monitor.runProfile.recordBitrateInvalid": {
    ja: "recordBitrateKbps は正の整数で入力してください。",
    en: "Enter recordBitrateKbps as a positive integer.",
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
  "monitor.device.physicalUdidRequired": {
    ja: "実機には udid が必要です(xcrun devicectl list devices で確認できます)。",
    en: "A physical device requires udid (see: xcrun devicectl list devices).",
  },
  "monitor.device.physicalSerialRequired": {
    ja: "実機には serial が必要です(adb devices の左列です)。",
    en: "A physical device requires serial (the left column of: adb devices).",
  },
  "monitor.device.physicalBadge": {
    ja: "実機",
    en: "Device",
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
  "monitor.healthWatch.displayRepairAttempt": {
    ja: "画面リセット(sleep/wake)による修復を試みます。",
    en: "Attempting repair by resetting the display (sleep/wake).",
  },
  "monitor.healthWatch.displayRepairExecuted": {
    ja: "画面リセットで凍結が解消しました。",
    en: "The display reset cleared the freeze.",
  },
  "monitor.healthWatch.displayRepairFailed": {
    ja: "画面リセットでは解消しませんでした(クールダウン後に次段の修復へ進みます)。",
    en: "The display reset did not clear the freeze (escalating to the next repair after cooldown).",
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
  // 設定タブ「更新する」の確認(モーダル)。webview では confirm が効かないのでホスト側で出す。
  "monitor.update.confirmMessage": {
    ja: "ftester を更新します。git pull・再ビルド・拡張の再インストールを行い、数分かかります。続けますか?",
    en: "Update ftester? It runs git pull, rebuild, and extension reinstall, and takes a few minutes.",
  },
  "monitor.update.confirmButton": { ja: "更新する", en: "Update" },
  // 「更新を確認」で更新が見つかったとき、その場で適用するか聞く(押した本人はもう考えている)。
  "monitor.update.foundMessage": {
    ja: "ftester に更新があります({local} → {remote})。今すぐ更新しますか?",
    en: "An ftester update is available ({local} -> {remote}). Update now?",
  },
  // 更新実行中の進捗通知(withProgress)のタイトル。パネル非表示でも進行が見えるように出す。
  "monitor.update.progressTitle": { ja: "ftester を更新しています", en: "Updating ftester" },
  // 更新の完了/失敗。ログ行は OUTPUT へ、通知は再読み込みの導線として出す。
  "monitor.update.finishedOkLog": {
    ja: "==> 更新が完了しました。反映するにはウィンドウの再読み込みが必要です。",
    en: "==> Update complete. A window reload is required to apply it.",
  },
  "monitor.update.finishedOk": {
    ja: "ftester の更新が完了しました。反映するにはウィンドウを再読み込みしてください。",
    en: "The ftester update is complete. Reload the window to apply it.",
  },
  // モーダルの本文(detail)。閉じても更新自体は済んでいることを明示する。
  "monitor.update.finishedOkDetail": {
    ja: "拡張と CLI を入れ替えました。ウィンドウを再読み込みするまで、この画面では更新前の拡張が動き続けます(あとで「Developer: Reload Window」でも反映できます)。",
    en: "The extension and CLI have been replaced. Until you reload the window, this window keeps running the previous extension (you can also apply it later via \"Developer: Reload Window\").",
  },
  "monitor.update.reloadButton": { ja: "再読み込み", en: "Reload window" },
  "monitor.update.finishedFailedLog": {
    ja: "==> 更新に失敗しました(終了コード {code})。上の [fail] 行を確認してください。",
    en: "==> Update failed (exit code {code}). Check the [fail] line above.",
  },
  "monitor.update.finishedFailed": {
    ja: "ftester の更新に失敗しました(終了コード {code})。詳細は OUTPUT の ftester を確認してください。",
    en: "The ftester update failed (exit code {code}). See the ftester OUTPUT channel for details.",
  },
  // 設定タブ「更新」実行時、ログ領域の1行目(monitorUpdateController.ts)。
  "monitor.update.startLog": {
    ja: "==> 更新を開始します(Scripts/update.sh)",
    en: "==> Starting the update (Scripts/update.sh)",
  },
} satisfies MessageDict;
