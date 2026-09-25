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
  "monitor.deviceOp.labelWiping": { ja: "Wipe Data 実行中...", en: "Wiping data..." },
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

  // ---- monitorProfileForms.ts: validateNewProjectName ----
  // 規則は Sources/FTCore/TestProject.swift の ProjectStore.isValidName と同じ(SPM ターゲット名の
  // 制約。test/projectNameRuleSync.test.mjs が正規表現を突き合わせる)。
  "monitor.project.nameNoSpaces": {
    ja: "テストプロジェクト名の前後に空白を含めることはできません。",
    en: "The test project name cannot have leading or trailing spaces.",
  },
  "monitor.project.nameRequired": {
    ja: "テストプロジェクト名を入力してください。",
    en: "Enter a test project name.",
  },
  "monitor.project.nameInvalid": {
    ja: "テストプロジェクト名は半角英数字・アンダースコア・ハイフンのみが使え、先頭にハイフンは使えません。",
    en: "The test project name may only contain ASCII letters, digits, underscores, and hyphens, and cannot start with a hyphen.",
  },
  "monitor.project.nameExists": {
    ja: "テストプロジェクト「{name}」は既に存在します。",
    en: 'Test project "{name}" already exists.',
  },

  // ---- monitorModel.ts: validateNewDeviceName ----
  "monitor.device.nameRequired": {
    ja: "デバイス名を入力してください。",
    en: "Enter a device name.",
  },
  "monitor.validation.nameAlreadyExists": {
    ja: "「{name}」は既に存在します。",
    en: '"{name}" already exists.',
  },

  // ---- monitorPanel.ts ----
  "monitor.statusBar.label": {
    ja: "$(device-mobile) fleetest mobile",
    en: "$(device-mobile) fleetest mobile",
  },
  "monitor.statusBar.tooltip": {
    ja: "fleetest: デバイスモニターを表示",
    en: "fleetest: Show device monitor",
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
  "monitor.residentKillClose.error": {
    ja: "常駐プロセスの停止に失敗しました: {error}",
    en: "Failed to stop resident processes: {error}",
  },
  // 「すべて終了」の確認(モーダル)。webview では confirm が効かないのでホスト側で出す。
  "monitor.residentKillClose.confirmMessage": {
    ja: "常駐プロセスを終了してモニターパネルを閉じます。他のセッション・MCP が使用中のブリッジは止めません。続けますか?",
    en: "Stop resident processes and close the monitor panel? Bridges in use by other sessions or MCP are not stopped.",
  },
  // runCount > 0 のときだけ modal の detail に足す。
  "monitor.residentKillClose.confirmDetailRuns": {
    ja: "実行中の run が {count} 本あります。run には強制終了(SIGKILL)ではなく終了要求(SIGTERM)を送ります。",
    en: "{count} run(s) are in progress. They will receive a termination request (SIGTERM), not a forced kill (SIGKILL).",
  },
  "monitor.residentKillClose.confirmButton": { ja: "終了して閉じる", en: "Stop and Close" },
  // bridge down が lease/MCP の印で断られた(非 0 終了)ときに OUTPUT へ出す1行。cmd は
  // "bridge down --all" / "bridge down --platform android"。
  "monitor.log.residentKillBridgeRefused": {
    ja: "{cmd} が断られたため(exit {exitCode})、ブリッジ系の常駐プロセスは残します。",
    en: "{cmd} was refused (exit {exitCode}); leaving bridge-related resident processes running.",
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
  "monitor.bridgeWatch.repairDeferredInRun": {
    ja: "実行中のためブリッジの修復を保留します。",
    en: "Deferring bridge repair because a run is in progress.",
  },

  // ---- monitorDeviceStreamController.ts ----
  "monitor.deviceStream.fallbackToPolling": {
    ja: "ポーリングへ戻します。",
    en: "Falling back to polling.",
  },
  // 設定タブのマシン削除の確認(モーダル)。webview では confirm が効かないのでホスト側で出す。
  "monitor.remoteHosts.removeConfirm": {
    ja: "マシン「{machine}」の登録を削除しますか?",
    en: "Remove the machine \"{machine}\"?",
  },
  "monitor.remoteHosts.removeConfirmDetail": {
    ja: "この Mac のマシン登録簿から外します。ランナー機の上のファイルやデバイスは変更しません。",
    en: "It is removed from this Mac's machine registry. Files and devices on the runner are not changed.",
  },
  "monitor.remoteHosts.removeButton": { ja: "削除", en: "Remove" },
  // 設定タブ「更新する」の確認(モーダル)。webview では confirm が効かないのでホスト側で出す。
  "monitor.update.confirmMessage": {
    ja: "fleetest を更新します。git pull・再ビルド・拡張の再インストールを行い、数分かかります。続けますか?",
    en: "Update fleetest? It runs git pull, rebuild, and extension reinstall, and takes a few minutes.",
  },
  "monitor.update.confirmButton": { ja: "更新する", en: "Update" },
  // 「今すぐクリーンアップ」の確認(モーダル)。webview では confirm が効かないのでホスト側で出す。
  // 消える合計は先に撃った --dry-run の結果({size} は "12.3 GB" の形)。
  "monitor.cleanup.confirmMessage": {
    ja: "{size} を削除します。元に戻せません。続けますか?",
    en: "Delete {size}? This cannot be undone. Continue?",
  },
  // 見積もりが読めなかったとき(CLI が合計を返さない形のとき)も、消す前に必ず1回聞く。
  "monitor.cleanup.confirmMessageUnknownSize": {
    ja: "クリーンアップを実行します(削除量を見積もれませんでした)。元に戻せません。続けますか?",
    en: "Run cleanup? The amount to delete could not be estimated, and this cannot be undone.",
  },
  "monitor.cleanup.confirmButton": { ja: "削除する", en: "Delete" },
  // 「更新を確認」で更新が見つかったとき、その場で適用するか聞く(押した本人はもう考えている)。
  "monitor.update.foundMessage": {
    ja: "fleetest に更新があります({local} → {remote})。今すぐ更新しますか?",
    en: "An fleetest update is available ({local} -> {remote}). Update now?",
  },
  // 更新実行中の進捗通知(withProgress)のタイトル。パネル非表示でも進行が見えるように出す。
  "monitor.update.progressTitle": { ja: "fleetest を更新しています", en: "Updating fleetest" },
  // 更新の完了/失敗。ログ行は OUTPUT へ、通知は再読み込みの導線として出す。
  "monitor.update.finishedOkLog": {
    ja: "==> 更新が完了しました。反映するにはウィンドウの再読み込みが必要です。",
    en: "==> Update complete. A window reload is required to apply it.",
  },
  "monitor.update.finishedOk": {
    ja: "fleetest の更新が完了しました。反映するにはウィンドウを再読み込みしてください。",
    en: "The fleetest update is complete. Reload the window to apply it.",
  },
  "monitor.update.reloadButton": { ja: "再読み込み", en: "Reload window" },
  "monitor.update.finishedFailedLog": {
    ja: "==> 更新に失敗しました(終了コード {code})。上の [fail] 行を確認してください。",
    en: "==> Update failed (exit code {code}). Check the [fail] line above.",
  },
  "monitor.update.finishedFailed": {
    ja: "fleetest の更新に失敗しました(終了コード {code})。詳細は OUTPUT の fleetest を確認してください。",
    en: "The fleetest update failed (exit code {code}). See the fleetest OUTPUT channel for details.",
  },
  // 設定タブ「更新」実行時、ログ領域の1行目(monitorUpdateController.ts)。
  "monitor.update.startLog": {
    ja: "==> 更新を開始します(Scripts/update.sh)",
    en: "==> Starting the update (Scripts/update.sh)",
  },
} satisfies MessageDict;
