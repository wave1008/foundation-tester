// バッチI 辞書(webview 側)。namespace: wvMonitor.
// 対象ソース: webview/monitor/{deviceTiles,modals,liveTab}.js
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "wvMonitor." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewMonitorAStrings = {
  "wvMonitor.footer.bridgeFailedPhysical": { ja: "デバイス未接続", en: "Device not connected" },
  "wvMonitor.footer.bridgeFailedVirtual": { ja: "接続できません", en: "Cannot connect" },
  "wvMonitor.footer.bridgeFailedTip": { ja: "ブリッジへの自動復旧に失敗しました(詳細は fleetest 出力)", en: "Auto-recovery of the bridge failed (see fleetest output)" },
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
  "wvMonitor.deviceOpMenu.wiping": { ja: "Wipe Data 実行中...", en: "Wiping data..." },
  "wvMonitor.deviceOpMenu.start": { ja: "起動", en: "Start" },
  "wvMonitor.deviceOpMenu.stop": { ja: "停止", en: "Stop" },
  // 実機は端末そのものを起動・停止しない(操作対象はブリッジだけ)ので別ラベルにする
  "wvMonitor.deviceOpMenu.startBridge": { ja: "ブリッジを起動", en: "Start bridge" },
  "wvMonitor.deviceOpMenu.stopBridge": { ja: "ブリッジを停止", en: "Stop bridge" },

  // 選択の当たりは画像だけ(画像の外側のクリックは全解除。deviceTiles.js の click 委譲)
  "wvMonitor.tile.title": {
    ja: "画像をクリックで選択 / 右クリックで起動・停止・ライブ操作",
    en: "Click the screen to select / right-click to Start, Stop, or open Live Control",
  },
  "wvMonitor.tile.running": { ja: "実行中", en: "Running" },
  "wvMonitor.tile.shuttingDown": { ja: "シャットダウン中", en: "Shutting down" },
  "wvMonitor.tile.waiting": { ja: "待機中", en: "Waiting" },
  "wvMonitor.tile.connecting": { ja: "接続中", en: "Connecting" },
  "wvMonitor.tile.cpuBadgeTitle": { ja: "CPU描画(swiftshader・フォールバック)", en: "CPU rendering (swiftshader fallback)" },
  "wvMonitor.tile.physicalBadge": { ja: "実機", en: "Device" },
  // リモートのデバイスはモニターから状態を観測できない(simctl/adb は手元にしか効かない)。
  // 「未起動」と言うと、向こうで起動していても止まっているように見える
  // 配信を諦めた(ホストがエンコードをこなせない等)。待っても来ないので「接続中」とは言わない。
  // **タイルは狭い(幅 60px 程度)ので短く** —— 理由と対処はツールチップへ
  "wvMonitor.tile.streamUnavailable": { ja: "映像なし", en: "No video" },
  "wvMonitor.tile.streamUnavailableTip": {
    ja: "映像を取得できませんでした(ホストがエンコードをこなせていない可能性があります)。配信するタイルを減らすか、設定タブの「ポーリングモードを使用する」を有効にしてください。詳細は OUTPUT の fleetest を参照。",
    en: "Could not get video (the host may be unable to encode). Stream fewer tiles, or turn on \"Use polling mode\" in the settings tab. See the fleetest OUTPUT channel for details.",
  },
  "wvMonitor.tile.stateUnknownTip": {
    ja: "この機械からは状態を観測できません(simctl/adb は手元にしか効きません)。その機械の fleetest の版が揃っているか確認してください。",
    en: "This machine cannot observe the state (simctl/adb are local only). Check that the other machine's fleetest is on the same version.",
  },
  "wvMonitor.tile.stateUnknown": { ja: "状態不明", en: "Unknown" },
  // fleetest monitor pause 中(state=unknown + detail 'held…')。タイルは狭いので短く
  "wvMonitor.tile.monitorPaused": { ja: "モニタ停止中", en: "Monitor paused" },
  "wvMonitor.tile.monitorPausedTip": {
    ja: "fleetest monitor pause で観測と配信を停止しています。fleetest monitor resume(または --for の期限切れ)で再開します。",
    en: "Observation and streaming are held by `fleetest monitor pause`. Resume with `fleetest monitor resume` (or when the --for window expires).",
  },
  // 繋がっている iOS 実機でブリッジが起きていないだけの状態。**「未起動」と言わない** ——
  // 端末は動いており、無いのはブリッジだけ(タイルのメニューから起こせる)
  "wvMonitor.tile.bridgeNotRunning": { ja: "ブリッジ未起動", en: "No bridge" },
  "wvMonitor.tile.remoteUnobservable": {
    ja: "{machine}\n状態不明",
    en: "{machine}\nunknown",
  },
  // 登録はあるのに一覧に無いデバイス(実体を手で消した等)。リモートの実体は手元から見えないので、
  // ここで出さないと「実行して落ちるまで気付けない」
  "wvMonitor.devicePick.missingBadge": { ja: "実体なし", en: "Not installed" },
  "wvMonitor.devicePick.missingDetail": {
    ja: "登録: {identifier}(このホストに実体がありません。チェックを外すと登録を解除します)",
    en: "Registered as {identifier} (no such device on this host; uncheck to unregister)",
  },
  // avdmanager 不在の解決手段。**導入先はカタログを取った機械**なので、ローカルは導入ボタン、
  // リモートは remote exec の案内を出す(手元へ入れても向こうの欠けは埋まらない)
  "wvMonitor.deviceAdd.installCmdlineToolsOnRemote": {
    ja: "導入は {machine} 側で行います: fleetest remote exec {machine} -- api install-cmdline-tools",
    en: "Install it on {machine}: fleetest remote exec {machine} -- api install-cmdline-tools",
  },
  "wvMonitor.tile.physicalBadgeTitle": {
    ja: "実機(シミュレータ/エミュレータではありません)。起動・停止は行いません",
    en: "Physical device (not a simulator/emulator). It is never started or stopped.",
  },
  // **絵文字1文字**(言語に依らないので ja/en 同値)。意味は title(frozenTitle)が担うので、
  // バッジの文字を増やさない = 狭いタイルのフッターで他のバッジを押し出さない
  "wvMonitor.tile.frozen": { ja: "❄️", en: "❄️" },
  // タイルの ❄️ バッジの説明(hoverTip)。バッジが絵文字1文字なので意味はここが担う
  "wvMonitor.tile.frozenTitle": {
    ja: "デバイス凍結中",
    en: "Device frozen",
  },
  "wvMonitor.tile.unregistered": { ja: "未登録", en: "Unregistered" },
  "wvMonitor.tile.unregisteredTitle": {
    ja: "マシンプロファイル未記載の起動中デバイスです。起動は行えません(停止・ライブ操作は可能です)",
    en: "A running device not listed in the machine profile. Starting is unavailable (stopping and Live Control are available).",
  },
  // ツールバー右端の全選択トグル(deviceTiles.js が押すたびに title/aria-label を入れ替える)。
  "wvMonitor.toolbar.selectAll": { ja: "デバイスをすべて選択", en: "Select All Devices" },
  "wvMonitor.toolbar.deselectAll": { ja: "デバイスの選択をすべて解除", en: "Deselect All Devices" },

  "wvMonitor.tile.queuedRestart": { ja: "再起動待機", en: "Restart pending" },
  "wvMonitor.tile.queuedWipe": { ja: "Wipe 待機", en: "Wipe pending" },
  // タイル画像の位置に出す(幅が狭いので短く。詳細は wipingTip)
  "wvMonitor.tile.wiping": { ja: "Wipe Data中", en: "Wiping data" },
  "wvMonitor.tile.wipeStopping": { ja: "Wipe: 停止中", en: "Wipe: stopping" },
  "wvMonitor.tile.wipeRebooting": { ja: "Wipe: 再起動中", en: "Wipe: restarting" },
  "wvMonitor.tile.wipingTip": {
    ja: "データを消去しています。停止 → 消去 → (起動していた台だけ)再起動の順で進みます(Android の初回起動は再構築で数分かかります)。",
    en: "Wiping the device's data: stop → wipe → start again (only if it was running). On Android the first boot rebuilds and takes minutes.",
  },
  "wvMonitor.tile.queuedStart": { ja: "起動待機", en: "Start pending" },

  "wvMonitor.deviceState.booting": { ja: "起動中", en: "Starting" },
  "wvMonitor.deviceState.offline": { ja: "未起動", en: "Not started" },

  "wvMonitor.bulk.cancelStart": { ja: "デバイスの起動を中断", en: "Cancel Starting Devices" },
  "wvMonitor.bulk.startAll": { ja: "デバイスを全て起動", en: "Start All Devices" },

  "wvMonitor.profile.none": { ja: "(プロファイルなし)", en: "(No profile)" },
  "wvMonitor.profile.running": { ja: "(起動中のデバイス)", en: "(Running devices)" },
  // バナーは自動では消えない(読む前に消えるため)。閉じ方を示す
  "wvMonitor.banner.dismissTip": { ja: "クリックで閉じる", en: "Click to dismiss" },
  "wvMonitor.banner.copy": { ja: "コピー", en: "Copy" },
  "wvMonitor.banner.copied": { ja: "コピーしました", en: "Copied" },
  "wvMonitor.banner.copyTip": {
    ja: "メッセージをコピーします(閉じません)",
    en: "Copy the message (does not dismiss it)",
  },
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
  // バッチ作成(modals.js)。件数は number 入力の min/max だけに任せない(手打ちで通る)
  "wvMonitor.deviceAdd.batchCountInvalid": {
    ja: "台数は 1〜99 で入力してください。",
    en: "Enter a number between 1 and 99.",
  },
  "wvMonitor.deviceBatch.creating": { ja: "作成中...", en: "Creating..." },
  "wvMonitor.deviceBatch.waiting": { ja: "待機中", en: "Waiting" },
  "wvMonitor.deviceBatch.done": { ja: "作成しました", en: "Created" },
  "wvMonitor.deviceBatch.failed": { ja: "失敗", en: "Failed" },
  "wvMonitor.deviceBatch.progress": {
    ja: "{done}/{total} 台",
    en: "{done}/{total} devices",
  },
  "wvMonitor.deviceBatch.finished": {
    ja: "{created} 台を作成しました({failed} 台が失敗)。OK を押すと作成したデバイスにチェックが入ります。",
    en: "Created {created} device(s), {failed} failed. Pressing OK checks the created devices.",
  },
  "wvMonitor.deviceBatch.finishedAllOk": {
    ja: "{created} 台を作成しました。OK を押すと作成したデバイスにチェックが入ります。",
    en: "Created {created} device(s). Pressing OK checks the created devices.",
  },
  "wvMonitor.deviceAdd.installing": {
    ja: "導入中... (進捗は OUTPUT の fleetest)",
    en: "Installing... (progress in the fleetest OUTPUT channel)",
  },
  "wvMonitor.deviceAdd.installFailed": {
    ja: "Command-line Tools の導入に失敗しました。",
    en: "Failed to install the Command-line Tools.",
  },
  "wvMonitor.deviceAdd.createFailed": { ja: "デバイスの作成に失敗しました。", en: "Failed to create the device." },
  "wvMonitor.deviceAdd.creating": { ja: "作成中...", en: "Creating..." },

  // #device-pick-overlay 内のマシン選択(#device-pick-machine-select・devicePickMachine.js)。
  // モーダルを開いている間、どのマシンから取得しているかを常時表示するバッジにも使う
  // (「黙って別マシンの一覧を出さない」ため。#device-add-source-badge はこのバッジの読み取り専用複製)。
  "wvMonitor.devicePick.machineLocalOption": { ja: "ローカル(このマシン)", en: "Local (this machine)" },
  "wvMonitor.devicePick.machineLocalShort": { ja: "ローカル", en: "local" },
  "wvMonitor.devicePick.machineBadge": { ja: "マシン: {source}", en: "Machine: {source}" },

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
  "wvMonitor.devicePick.fetchFailed": { ja: "一覧の取得に失敗しました。", en: "Failed to retrieve the list." },
  "wvMonitor.devicePick.syncFailed": { ja: "デバイスの同期に失敗しました。", en: "Failed to sync devices." },
  // devicePickDeviceDeleteResult の error が空(理論上想定外)のときだけ使うフォールバック。
  // 通常はホスト側が理由文を必ず載せる(monitorDeviceOps.ts の deleteOps.deleteFailedGeneric)。
  "wvMonitor.devicePick.deleteFailed": { ja: "デバイスの削除に失敗しました。", en: "Failed to delete the device." },
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
