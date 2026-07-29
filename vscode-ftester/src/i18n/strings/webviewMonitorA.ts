// バッチI 辞書(webview 側)。namespace: wvMonitor.
// 対象ソース: webview/monitor/{deviceTiles,modals,liveTab}.js
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "wvMonitor." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewMonitorAStrings = {
  "wvMonitor.footer.bridgeFailedPhysical": { ja: "デバイス未接続", en: "Device not connected" },
  "wvMonitor.footer.bridgeFailedVirtual": { ja: "接続できません", en: "Cannot connect" },
  "wvMonitor.footer.bridgeFailedTip": { ja: "ブリッジへの自動復旧に失敗しました(詳細は ftester 出力)", en: "Auto-recovery of the bridge failed (see ftester output)" },
  "wvMonitor.footer.healthUnhealthy": { ja: "デバイス異常を検出", en: "Device issue detected" },
  "wvMonitor.footer.healthWifiRepairing": { ja: "Wi-Fi 修復中...", en: "Repairing Wi-Fi..." },
  "wvMonitor.footer.healthDisplayRepairing": { ja: "画面リセット修復中...", en: "Resetting display..." },
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
  // 実機は端末そのものを起動・停止しない(操作対象はブリッジだけ)ので別ラベルにする
  "wvMonitor.deviceOpMenu.startBridge": { ja: "ブリッジを起動", en: "Start bridge" },
  "wvMonitor.deviceOpMenu.stopBridge": { ja: "ブリッジを停止", en: "Stop bridge" },

  "wvMonitor.tile.title": {
    ja: "クリックで選択 / 右クリックで起動・停止・ライブ操作",
    en: "Click to select / right-click to Start, Stop, or open Live Control",
  },
  "wvMonitor.tile.running": { ja: "実行中", en: "Running" },
  "wvMonitor.tile.shuttingDown": { ja: "シャットダウン中", en: "Shutting down" },
  "wvMonitor.tile.waiting": { ja: "待機中", en: "Waiting" },
  "wvMonitor.tile.connecting": { ja: "接続中", en: "Connecting" },
  "wvMonitor.tile.cpuBadgeTitle": { ja: "CPU描画(swiftshader・フォールバック)", en: "CPU rendering (swiftshader fallback)" },
  "wvMonitor.tile.physicalBadge": { ja: "実機", en: "Device" },
  "wvMonitor.tile.physicalBadgeTitle": {
    ja: "実機(シミュレータ/エミュレータではありません)。起動・停止は行いません",
    en: "Physical device (not a simulator/emulator). It is never started or stopped.",
  },
  "wvMonitor.tile.queuedRestart": { ja: "再起動待機", en: "Restart pending" },
  "wvMonitor.tile.queuedStart": { ja: "起動待機", en: "Start pending" },

  "wvMonitor.deviceState.booting": { ja: "起動中", en: "Starting" },
  "wvMonitor.deviceState.offline": { ja: "未起動", en: "Not started" },

  "wvMonitor.bulk.cancelStart": { ja: "デバイスの起動を中断", en: "Cancel Starting Devices" },
  "wvMonitor.bulk.startAll": { ja: "デバイスを全て起動", en: "Start All Devices" },

  "wvMonitor.profile.none": { ja: "(プロファイルなし)", en: "(No profile)" },
  "wvMonitor.profile.running": { ja: "(起動中のデバイス)", en: "(Running devices)" },
  "wvMonitor.bulk.startAllDisabledRunning": {
    ja: "「(起動中のデバイス)」表示中は使えません(未起動のデバイスが一覧に出ないため)。「(プロファイルなし)」か実行プロファイルを選んでください。",
    en: "Unavailable while showing \"(Running devices)\" because devices that are not started are hidden. Select \"(No profile)\" or a run profile.",
  },

  "wvMonitor.deviceAdd.nameRequired": { ja: "デバイス名を入力してください。", en: "Please enter a device name." },
  "wvMonitor.deviceAdd.nameDuplicate": { ja: "「{name}」は既に存在します。", en: "\"{name}\" already exists." },
  "wvMonitor.deviceAdd.catalogLoading": { ja: "カタログを読み込み中...", en: "Loading catalog..." },
  "wvMonitor.deviceAdd.catalogFailed": { ja: "カタログの取得に失敗しました。", en: "Failed to load the catalog." },
  "wvMonitor.deviceAdd.catalogEmpty": {
    ja: "この OS 種別で選べるモデル/OSバージョンがありません。",
    en: "No models or OS versions are available for this OS type.",
  },
  "wvMonitor.deviceAdd.noImageForService": {
    ja: "選択したサービスのシステムイメージがありません(別のサービスを選ぶか、Android Studio の SDK Manager で追加してください)。",
    en: "No system image for the selected services (pick another one, or add it in Android Studio's SDK Manager).",
  },
  "wvMonitor.deviceAdd.installing": {
    ja: "導入中... (進捗は OUTPUT の ftester)",
    en: "Installing... (progress in the ftester OUTPUT channel)",
  },
  "wvMonitor.deviceAdd.installFailed": {
    ja: "Command-line Tools の導入に失敗しました。",
    en: "Failed to install the Command-line Tools.",
  },
  "wvMonitor.deviceAdd.createFailed": { ja: "デバイスの作成に失敗しました。", en: "Failed to create the device." },
  "wvMonitor.deviceAdd.creating": { ja: "作成中...", en: "Creating..." },

  "wvMonitor.nameInput.required": { ja: "{noun}を入力してください。", en: "Please enter {noun}." },
  "wvMonitor.nameInput.forbiddenChars": {
    ja: "{noun}に \"/\" や \"{backslash}\" は使えません。",
    en: "{noun} cannot contain \"/\" or \"{backslash}\".",
  },
  "wvMonitor.nameInput.leadingDot": { ja: "{noun}を \".\" で始めることはできません。", en: "{noun} cannot start with \".\"." },
  "wvMonitor.nameInput.duplicate": { ja: "{dupLabel}「{name}」は既に存在します。", en: "{dupLabel}\"{name}\" already exists." },

  // グループにはシミュレータ/AVD だけでなく接続中の実機も並ぶため「デバイス」と呼ぶ
  // (count は実機を含む合計)
  "wvMonitor.devicePick.iosCountTitle": { ja: "iOS デバイス ({count})", en: "iOS devices ({count})" },
  "wvMonitor.devicePick.androidCountTitle": { ja: "Android デバイス ({count})", en: "Android devices ({count})" },
  "wvMonitor.devicePick.iosFetchFailed": { ja: "iOS シミュレータを取得できませんでした(実機は別に取得します)。", en: "Failed to retrieve iOS simulators (physical devices are retrieved separately)." },
  "wvMonitor.devicePick.iosEmpty": { ja: "iOS シミュレータも接続中の実機もありません。", en: "No iOS simulators or connected devices." },
  "wvMonitor.devicePick.androidFetchFailed": { ja: "Android AVD を取得できませんでした(実機は別に取得します)。", en: "Failed to retrieve Android AVDs (physical devices are retrieved separately)." },
  "wvMonitor.devicePick.androidEmpty": { ja: "Android AVD も接続中の実機もありません。", en: "No Android AVDs or connected devices." },
  "wvMonitor.devicePick.iosTitle": { ja: "iOS デバイス", en: "iOS devices" },
  "wvMonitor.devicePick.androidTitle": { ja: "Android デバイス", en: "Android devices" },
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
  "wvMonitor.live.detailUnset": { ja: "—", en: "—" },
} satisfies MessageDict;
