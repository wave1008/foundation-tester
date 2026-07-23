// バッチB 辞書。namespace: panels.
// 対象ソース: monitorHtml.ts, livePanelHtml.ts(静的 HTML のタブ名・ボタン・title 属性など)
// キーは "panels." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const panelsStrings = {
  "panels.tabs.devices": { ja: "デバイス", en: "Devices" },
  "panels.tabs.profiles": { ja: "プロファイル", en: "Profiles" },
  "panels.tabs.processes": { ja: "プロセス", en: "Processes" },
  "panels.tabs.recordings": { ja: "録画", en: "Recordings" },
  "panels.tabs.settings": { ja: "設定", en: "Settings" },

  "panels.recordings.sessionsTitle": { ja: "録画セッション", en: "Recording Sessions" },
  "panels.recordings.refresh": { ja: "更新", en: "Refresh" },
  "panels.recordings.backTitle": { ja: "セッション一覧に戻る", en: "Back to session list" },
  "panels.recordings.playPauseTitle": { ja: "再生 / 一時停止", en: "Play / Pause" },
  "panels.recordings.prevTestTitle": { ja: "前のテストへ", en: "Previous test" },
  "panels.recordings.nextTestTitle": { ja: "次のテストへ", en: "Next test" },
  "panels.recordings.rewindTitle": { ja: "10秒巻き戻し", en: "Rewind 10 seconds" },
  "panels.recordings.forwardTitle": { ja: "10秒早送り", en: "Forward 10 seconds" },
  "panels.recordings.seekAriaLabel": { ja: "再生位置", en: "Playback position" },
  "panels.recordings.errorsTitle": { ja: "エラー一覧", en: "Errors" },
  "panels.recordings.treeTitle": { ja: "テスト", en: "Tests" },
  "panels.recordings.expandAllTitle": { ja: "全て開く", en: "Expand all" },
  "panels.recordings.collapseAllTitle": { ja: "全て閉じる", en: "Collapse all" },
  "panels.recordings.filterClear": { ja: "解除", en: "Clear" },
  "panels.recordings.splitterTitle": { ja: "ドラッグで幅を調整", en: "Drag to resize" },
  "panels.recordings.filterClearTitle": {
    ja: "エラー一覧のフィルターを解除(ツリーの選択中ノードをもう一度クリックしても解除できます)",
    en: "Clear the error-list filter (clicking the selected tree node again also clears it)",
  },

  "panels.common.runProfile": { ja: "実行プロファイル", en: "Run Profile" },
  "panels.common.appProfile": { ja: "アプリプロファイル", en: "App Profile" },
  "panels.common.machineProfile": { ja: "マシンプロファイル", en: "Machine Profile" },
  "panels.common.devices": { ja: "デバイス", en: "Devices" },
  "panels.common.deviceLabelColon": { ja: "デバイス:", en: "Device:" },
  "panels.common.refreshDeviceList": { ja: "デバイス一覧を更新", en: "Refresh Device List" },
  "panels.common.confirm": { ja: "確定", en: "Confirm" },
  "panels.common.cancel": { ja: "キャンセル", en: "Cancel" },
  "panels.common.runLog": { ja: "実行ログ", en: "Run Log" },
  "panels.common.port": { ja: "ポート", en: "Port" },
  "panels.common.required": { ja: "必須", en: "Required" },

  "panels.toolbar.runProfileSelectTitle": {
    ja: "以後のテスト実行・デバッグ実行と、このモニターの監視対象デバイスに使う実行プロファイル(ftester.profile 設定)",
    en: "Run profile used for subsequent test/debug runs and this monitor's watched devices (ftester.profile setting)",
  },
  "panels.toolbar.startAllDevices": { ja: "デバイスを全て起動", en: "Start All Devices" },
  "panels.toolbar.stopAll": { ja: "全て終了", en: "Stop All" },
  "panels.toolbar.restartMonitor": { ja: "モニター再起動", en: "Restart Monitor" },
  "panels.hostMetrics.memTitle": { ja: "メモリ使用量", en: "Memory usage" },
  "panels.hostMetrics.cpuTitle": { ja: "CPU負荷", en: "CPU load" },
  "panels.hostMetrics.gpuTitle": { ja: "GPU負荷", en: "GPU load" },
  "panels.hostMetrics.fmTitle": { ja: "FM 呼び出し回数", en: "FM call count" },

  "panels.devices.emptyMessage": {
    ja: "デバイス情報を待機しています(ポーリング形式のため反映まで数十秒かかることがあります)...",
    en: "Waiting for device information (this may take tens of seconds to reflect since it uses polling)...",
  },
  "panels.devices.splitterAriaLabel": { ja: "タイルと出力の分割境界線", en: "Divider between tiles and output" },
  "panels.devices.lanesPlaceholder": {
    ja: "テストを実行するとデバイス毎の出力がここに表示されます",
    en: "Output for each device appears here once a test runs",
  },

  "panels.runProfile.noneSelected": { ja: "(実行プロファイルなし)", en: "(No run profile)" },
  "panels.runProfile.addTitle": { ja: "実行プロファイルの追加", en: "Add run profile" },
  "panels.runProfile.copyTitle": { ja: "実行プロファイルのコピー", en: "Copy run profile" },
  "panels.runProfile.removeTitle": { ja: "実行プロファイルの削除", en: "Delete run profile" },
  "panels.runProfile.renameTitle": { ja: "実行プロファイル名の変更", en: "Rename run profile" },
  "panels.runProfile.machineLabel": { ja: "使用するマシンプロファイル", en: "Machine profile to use" },
  "panels.runProfile.appLabel": { ja: "アプリ", en: "App" },
  "panels.runProfile.healLabel": { ja: "自己修復(heal)を有効にする", en: "Enable self-heal" },
  "panels.runProfile.inappEngineLabel": {
    ja: "高速なinappエンジンを使用する(iOS)",
    en: "Use the fast in-app engine (iOS)",
  },
  "panels.runProfile.wipeOnBloatLabel": {
    ja: "イメージ肥大時に自動で Wipe Data する(Android)",
    en: "Automatically wipe data when the image bloats (Android)",
  },
  "panels.runProfile.wipeThresholdLabel": { ja: "Wipe Data しきい値(GB)", en: "Wipe data threshold (GB)" },
  "panels.runProfile.recordLabel": { ja: "録画する", en: "Record video" },
  "panels.runProfile.localeLabel": { ja: "ロケール", en: "Locale" },

  "panels.appProfile.noneSelected": { ja: "(アプリプロファイルなし)", en: "(No app profile)" },
  "panels.appProfile.addTitle": { ja: "アプリプロファイルの追加", en: "Add app profile" },
  "panels.appProfile.copyTitle": { ja: "アプリプロファイルのコピー", en: "Copy app profile" },
  "panels.appProfile.removeTitle": { ja: "アプリプロファイルの削除", en: "Delete app profile" },
  "panels.appProfile.renameTitle": { ja: "アプリプロファイル名の変更", en: "Rename app profile" },
  "panels.appProfile.commonGroupTitle": { ja: "共通", en: "Common" },
  "panels.appProfile.displayNameLabel": { ja: "表示名", en: "Display Name" },
  "panels.appProfile.autoInstallLabel": { ja: "自動インストールを有効にする", en: "Enable auto install" },
  "panels.appProfile.appIdLabel": { ja: "アプリID", en: "App ID" },
  "panels.appProfile.packagePathLabel": { ja: "パッケージパス", en: "Package Path" },
  "panels.appProfile.packageNamePlaceholder": { ja: "パッケージ名", en: "Package name" },

  "panels.machineProfile.addTitle": { ja: "マシンプロファイルの追加", en: "Add machine profile" },
  "panels.machineProfile.copyTitle": { ja: "マシンプロファイルのコピー", en: "Copy machine profile" },
  "panels.machineProfile.removeTitle": { ja: "マシンプロファイルの削除", en: "Delete machine profile" },
  "panels.machineProfile.renameTitle": { ja: "マシンプロファイル名の変更", en: "Rename machine profile" },
  "panels.machineProfile.addExistingTitle": {
    ja: "インストール済みのシミュレータ/AVDからマシンプロファイルに追加",
    en: "Add from an installed simulator/AVD to the machine profile",
  },
  "panels.machineProfile.selectPrompt": {
    ja: "デバイスを選択すると内容を表示します",
    en: "Select a device to view details",
  },
  "panels.machineProfile.nameLabel": { ja: "名前", en: "Name" },
  "panels.machineProfile.modelLabel": { ja: "機種", en: "Model" },
  "panels.machineProfile.modelReadonlyTitle": {
    ja: "機種は変更できません(変更するにはデバイスを除去して作り直してください)",
    en: "Model cannot be changed (remove and recreate the device to change it)",
  },
  "panels.machineProfile.osReadonlyTitle": {
    ja: "OSは変更できません(変更するにはデバイスを除去して作り直してください)",
    en: "OS cannot be changed (remove and recreate the device to change it)",
  },
  "panels.machineProfile.udidReadonlyTitle": {
    ja: "UDIDは作成時に決まる識別子のため変更できません",
    en: "UDID is fixed at creation time and cannot be changed",
  },
  "panels.machineProfile.avdReadonlyTitle": {
    ja: "AVDは変更できません(変更するにはデバイスを除去して作り直してください)",
    en: "AVD cannot be changed (remove and recreate the device to change it)",
  },

  "panels.processes.title": { ja: "常駐プロセス", en: "Resident Processes" },
  "panels.processes.killAll": { ja: "すべて強制終了", en: "Force Stop All" },
  "panels.processes.colType": { ja: "種別", en: "Type" },
  "panels.processes.colDetail": { ja: "識別子", en: "Identifier" },
  "panels.processes.colParentPid": { ja: "親PID", en: "Parent PID" },
  "panels.processes.colParentProcess": { ja: "親プロセス", en: "Parent Process" },
  "panels.processes.colNote": { ja: "補足", en: "Note" },

  "panels.settings.pollingModeLabel": { ja: "ポーリングモードを使用する", en: "Use polling mode" },
  "panels.settings.pollingModeHint": {
    ja: "オンにすると画面を映像ストリーミングせず、従来のポーリング(定期スクリーンショット)で更新します。ストリーミングが不安定なときの回避用です。",
    en: "When enabled, the screen updates via traditional polling (periodic screenshots) instead of video streaming. Use this as a workaround when streaming is unstable.",
  },
  "panels.settings.languageLabel": { ja: "表示言語", en: "Display language" },
  "panels.settings.languageAuto": { ja: "自動(VS Code に追従)", en: "Auto (follow VS Code)" },
  "panels.settings.languageJa": { ja: "日本語", en: "日本語" },
  "panels.settings.languageEn": { ja: "English", en: "English" },
  "panels.settings.languageHint": {
    ja: "拡張の UI 表示言語(設定 ftester.language)。変更後、完全に反映するにはウィンドウの再読み込みが必要です。",
    en: "UI display language for the extension (setting: ftester.language). Reload the window after changing it to fully apply.",
  },

  "panels.deviceMenu.liveControl": { ja: "ライブ操作", en: "Live Control" },
  "panels.deviceMenu.restartWithGpu": { ja: "GPUで再起動", en: "Restart with GPU" },
  "panels.deviceMenu.remove": { ja: "除去", en: "Remove" },

  "panels.deviceAdd.title": { ja: "デバイスを追加", en: "Add Device" },
  "panels.deviceAdd.osTypeLabel": { ja: "OS種別", en: "OS Type" },
  "panels.deviceAdd.modelLabel": { ja: "モデル", en: "Model" },
  "panels.deviceAdd.osVersionLabel": { ja: "OSバージョン", en: "OS Version" },
  "panels.deviceAdd.nameLabel": { ja: "デバイス名", en: "Device Name" },

  "panels.devicePick.title": { ja: "既存のデバイスから選択", en: "Select from Existing Devices" },
  "panels.devicePick.addNewTitle": { ja: "デバイスを新規作成", en: "Create New Device" },
  "panels.devicePick.iosGroupTitle": { ja: "iOS シミュレータ", en: "iOS Simulators" },
  "panels.devicePick.note": {
    ja: "チェックを外して OK すると登録解除されます(シミュレータ/AVD 本体は削除されません)",
    en: "Unchecking and pressing OK unregisters the device (the simulator/AVD itself is not deleted)",
  },

  "panels.live.appProfileLabelColon": { ja: "アプリプロファイル:", en: "App Profile:" },
  "panels.live.startRecording": { ja: "レコーディング開始", en: "Start Recording" },
  "panels.live.stopRecording": { ja: "レコーディング終了", en: "Stop Recording" },
  "panels.live.screenshotAlt": { ja: "スクリーンショット", en: "Screenshot" },
  "panels.live.screenshotPlaceholder": {
    ja: "デバイスに接続されていません",
    en: "Device is not connected",
  },
  "panels.live.connectionErrorTitle": { ja: "⚠ デバイスに接続できません", en: "⚠ Cannot connect to device" },
  "panels.live.connectionErrorNote": {
    ja: "表示中の画面は最後に取得した状態です",
    en: "The screen shown is the last captured state",
  },
  "panels.live.homeButton": { ja: "ホーム", en: "Home" },
  "panels.live.homeButtonTitle": { ja: "ホーム画面に戻ります", en: "Return to the home screen" },
  "panels.live.appSwitcherButton": { ja: "タスク切替", en: "App Switcher" },
  "panels.live.appSwitcherTitle": {
    ja: "アプリスイッチャー(タスク一覧)を開きます",
    en: "Open the app switcher (task list)",
  },
  "panels.live.elementsHeader": { ja: "要素一覧(クリックでタップ)", en: "Elements (click to tap)" },
  "panels.live.refreshSnapshot": { ja: "要素一覧を更新", en: "Refresh Elements" },
  "panels.live.refreshSnapshotTitle": {
    ja: "要素一覧とタップ座標を現在の画面で取り直します。映像は自動更新されますが、操作なしで画面が変わった直後(非同期ロード・端末を直接操作など)に押すと要素一覧を拾い直せます。",
    en: "Re-captures the element list and tap coordinates from the current screen. Video updates automatically, but press this right after the screen changes without an action (async loads, direct device manipulation, etc.) to pick up the elements again.",
  },
  "panels.live.typeTextPlaceholder": { ja: "入力するテキスト(Enterで送信)", en: "Text to type (Enter to send)" },
  "panels.live.listsSplitterTitle": {
    ja: "ドラッグで要素一覧と操作記録の高さを調整",
    en: "Drag to resize the elements list and operation log",
  },
  "panels.live.screenSplitterTitle": {
    ja: "ドラッグでデバイス画像の幅を調整",
    en: "Drag to resize the device image width",
  },
  "panels.live.oplogHeader": { ja: "操作記録", en: "Operation Log" },
  "panels.live.oplogClear": { ja: "クリア", en: "Clear" },
  "panels.live.installButton": { ja: "インストール", en: "Install" },
  "panels.live.installButtonTitle": {
    ja: "選択中プロファイルのパッケージを選択デバイスにインストールします",
    en: "Install the selected profile's package to the selected device",
  },
  "panels.live.launchButton": { ja: "アプリを起動", en: "Launch App" },
  "panels.live.launchButtonTitle": {
    ja: "選択中プロファイルのアプリを選択デバイスで起動します",
    en: "Launch the selected profile's app on the selected device",
  },
  "panels.live.panelTitle": { ja: "ライブ操作", en: "Live Control" },
} satisfies MessageDict;
