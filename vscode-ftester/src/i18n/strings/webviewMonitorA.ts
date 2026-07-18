// バッチI 辞書(webview 側)。namespace: wvMonitor.
// 対象ソース: webview/monitor/{deviceTiles,modals,liveTab}.js
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "wvMonitor." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewMonitorAStrings = {
  "wvMonitor.footer.bridgeRepairFailed": { ja: "復旧失敗(ftester出力参照)", en: "Repair failed (see ftester output)" },
  "wvMonitor.footer.healthUnhealthy": { ja: "デバイス異常を検出", en: "Device issue detected" },
  "wvMonitor.footer.healthWifiRepairing": { ja: "Wi-Fi 修復中...", en: "Repairing Wi-Fi..." },
  "wvMonitor.footer.healthStreamRepairing": { ja: "ストリーム修復中...", en: "Repairing stream..." },
  "wvMonitor.footer.healthCpuFallback": { ja: "CPU描画で再起動中...", en: "Restarting with CPU rendering..." },
  "wvMonitor.footer.healthRestarting": { ja: "自動再起動中...", en: "Auto-restarting..." },
  "wvMonitor.footer.healthFailed": { ja: "自動修復失敗", en: "Auto-repair failed" },
  "wvMonitor.footer.wipeStopping": { ja: "🧹 Wipe Data(停止中)...", en: "🧹 Wipe Data (stopping)..." },
  "wvMonitor.footer.wipeRebooting": { ja: "🧹 Wipe Data(再起動中)...", en: "🧹 Wipe Data (restarting)..." },
  "wvMonitor.footer.wipeFailed": { ja: "🧹 Wipe Data失敗", en: "🧹 Wipe Data failed" },

  "wvMonitor.deviceOpMenu.queued": { ja: "待機中...", en: "Waiting..." },
  "wvMonitor.deviceOpMenu.startingUp": { ja: "起動中...", en: "Starting..." },
  "wvMonitor.deviceOpMenu.stoppingDown": { ja: "停止中...", en: "Stopping..." },
  "wvMonitor.deviceOpMenu.start": { ja: "起動", en: "Start" },
  "wvMonitor.deviceOpMenu.stop": { ja: "停止", en: "Stop" },

  "wvMonitor.tile.title": {
    ja: "クリックで選択 / 右クリックで起動・停止・ライブ操作",
    en: "Click to select / right-click to Start, Stop, or open Live Control",
  },
  "wvMonitor.tile.running": { ja: "実行中", en: "Running" },
  "wvMonitor.tile.shuttingDown": { ja: "シャットダウン中", en: "Shutting down" },
  "wvMonitor.tile.waiting": { ja: "待機中", en: "Waiting" },
  "wvMonitor.tile.connecting": { ja: "接続中", en: "Connecting" },
  "wvMonitor.tile.cpuBadgeTitle": { ja: "CPU描画(swiftshader・フォールバック)", en: "CPU rendering (swiftshader fallback)" },
  "wvMonitor.tile.queuedRestart": { ja: "再起動待機", en: "Restart pending" },
  "wvMonitor.tile.queuedStart": { ja: "起動待機", en: "Start pending" },

  "wvMonitor.deviceState.booting": { ja: "起動中", en: "Starting" },
  "wvMonitor.deviceState.offline": { ja: "未起動", en: "Not started" },

  "wvMonitor.bulk.cancelStart": { ja: "デバイスの起動を中断", en: "Cancel Starting Devices" },
  "wvMonitor.bulk.startAll": { ja: "デバイスを全て起動", en: "Start All Devices" },

  "wvMonitor.profile.none": { ja: "(プロファイルなし)", en: "(No profile)" },

  "wvMonitor.deviceAdd.nameRequired": { ja: "デバイス名を入力してください。", en: "Please enter a device name." },
  "wvMonitor.deviceAdd.nameDuplicate": { ja: "「{name}」は既に存在します。", en: "\"{name}\" already exists." },
  "wvMonitor.deviceAdd.catalogLoading": { ja: "カタログを読み込み中...", en: "Loading catalog..." },
  "wvMonitor.deviceAdd.catalogFailed": { ja: "カタログの取得に失敗しました。", en: "Failed to load the catalog." },
  "wvMonitor.deviceAdd.createFailed": { ja: "デバイスの作成に失敗しました。", en: "Failed to create the device." },
  "wvMonitor.deviceAdd.creating": { ja: "作成中...", en: "Creating..." },

  "wvMonitor.nameInput.required": { ja: "{noun}を入力してください。", en: "Please enter {noun}." },
  "wvMonitor.nameInput.forbiddenChars": {
    ja: "{noun}に \"/\" や \"{backslash}\" は使えません。",
    en: "{noun} cannot contain \"/\" or \"{backslash}\".",
  },
  "wvMonitor.nameInput.leadingDot": { ja: "{noun}を \".\" で始めることはできません。", en: "{noun} cannot start with \".\"." },
  "wvMonitor.nameInput.duplicate": { ja: "{dupLabel}「{name}」は既に存在します。", en: "{dupLabel}\"{name}\" already exists." },

  "wvMonitor.devicePick.iosCountTitle": { ja: "iOS シミュレータ ({count})", en: "iOS Simulators ({count})" },
  "wvMonitor.devicePick.iosFetchFailed": { ja: "iOS シミュレータを取得できませんでした。", en: "Failed to retrieve iOS Simulators." },
  "wvMonitor.devicePick.iosEmpty": { ja: "iOS シミュレータがありません。", en: "No iOS Simulators available." },
  "wvMonitor.devicePick.androidFetchFailed": { ja: "Android AVD を取得できませんでした。", en: "Failed to retrieve Android AVDs." },
  "wvMonitor.devicePick.androidEmpty": { ja: "Android AVD がありません。", en: "No Android AVDs available." },
  "wvMonitor.devicePick.iosTitle": { ja: "iOS シミュレータ", en: "iOS Simulators" },
  "wvMonitor.devicePick.loading": { ja: "一覧を読み込み中...", en: "Loading list..." },
  "wvMonitor.devicePick.fetchFailed": { ja: "一覧の取得に失敗しました。", en: "Failed to retrieve the list." },
  "wvMonitor.devicePick.syncFailed": { ja: "デバイスの同期に失敗しました。", en: "Failed to sync devices." },
  "wvMonitor.devicePick.applying": { ja: "適用中...", en: "Applying..." },
  "wvMonitor.devicePick.detailSeparator": { ja: "・", en: "·" },

  "wvMonitor.live.stateConnected": { ja: "接続済み", en: "Connected" },
  "wvMonitor.live.stateUnknown": { ja: "状態不明(未確認)", en: "Unknown (unconfirmed)" },
  "wvMonitor.live.processing": { ja: "処理中...", en: "Processing..." },
  "wvMonitor.live.notConnectedWarning": { ja: "⚠ 接続されていません", en: "⚠ Not connected" },
  "wvMonitor.live.noAppProfile": { ja: "(アプリプロファイルなし)", en: "(No app profile)" },
  "wvMonitor.live.recordStop": { ja: "レコーディング終了", en: "Stop Recording" },
  "wvMonitor.live.recordStart": { ja: "レコーディング開始", en: "Start Recording" },
  "wvMonitor.live.appProfileRequired": { ja: "アプリプロファイルが必要です", en: "An app profile is required" },
} satisfies MessageDict;
