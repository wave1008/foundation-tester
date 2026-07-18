// バッチJ 辞書(webview 側)。namespace: wvMonitor2.
// 対象ソース: webview/monitor/{runProfilesTab,processesTab,machineProfilesTab,appProfilesTab,
//   laneLog,hostCharts,splitter,h264Decoder,main,menu,tabs,settingsTab}.js,
//   webview/live/main.js
// webview バンドルから import される。**vscode 非依存**を保つこと。
// キーは "wvMonitor2." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const webviewMonitorBStrings = {
  // 共通(複数タブで再利用)
  "wvMonitor2.common.confirm": { ja: "確定", en: "Confirm" },
  "wvMonitor2.common.confirming": { ja: "確定中...", en: "Confirming..." },
  "wvMonitor2.common.loading": { ja: "読み込み中...", en: "Loading..." },
  "wvMonitor2.common.unspecified": { ja: "(未指定)", en: "(Unspecified)" },

  // runProfilesTab.js
  "wvMonitor2.runProfile.none": { ja: "実行プロファイルがありません。", en: "No run profiles." },
  "wvMonitor2.runProfile.loadFailed": {
    ja: "実行プロファイルを読み込めませんでした。",
    en: "Failed to load the run profile.",
  },
  "wvMonitor2.runProfile.selectMachineFirst": {
    ja: "マシンプロファイルを指定するとデバイスを選択できます",
    en: "Specify a machine profile to select devices",
  },
  "wvMonitor2.runProfile.deviceMissingFromMachine": {
    ja: "(マシンプロファイルにありません)",
    en: "(Not in the machine profile)",
  },
  "wvMonitor2.runProfile.validation.machineRequired": {
    ja: "使用するマシンプロファイルを指定してください。",
    en: "Specify the machine profile to use.",
  },
  "wvMonitor2.runProfile.validation.machineNotFound": {
    ja: "マシンプロファイル「{machine}」が見つかりません。",
    en: "Machine profile \"{machine}\" was not found.",
  },
  "wvMonitor2.runProfile.validation.appRequired": {
    ja: "アプリを指定してください。",
    en: "Specify an app.",
  },
  "wvMonitor2.runProfile.validation.deviceRequired": {
    ja: "デバイスを1台以上選択してください。",
    en: "Select at least one device.",
  },
  "wvMonitor2.runProfile.validation.timeoutInvalid": {
    ja: "defaultTimeout は正の整数で入力してください。",
    en: "Enter defaultTimeout as a positive integer.",
  },
  "wvMonitor2.runProfile.validation.wipeThresholdInvalid": {
    ja: "Wipe Data しきい値は正の数(GB)で入力してください。",
    en: "Enter the Wipe Data threshold as a positive number (GB).",
  },
  "wvMonitor2.runProfile.validation.localeInvalid": {
    ja: "ロケールは ja_JP のような形式で入力してください。",
    en: "Enter the locale in a format like ja_JP.",
  },
  "wvMonitor2.runProfile.saveFailed": {
    ja: "実行プロファイルの更新に失敗しました。",
    en: "Failed to update the run profile.",
  },

  // processesTab.js
  "wvMonitor2.process.empty": { ja: "常駐プロセスはありません", en: "No resident processes" },
  "wvMonitor2.process.zombieBadge": { ja: "ゾンビ", en: "Zombie" },
  "wvMonitor2.process.zombieTitle": {
    ja: "親に reap されていない defunct プロセス",
    en: "A defunct process not yet reaped by its parent",
  },
  "wvMonitor2.process.pendingLaunch": { ja: "(遅延起動)", en: "(Deferred launch)" },
  "wvMonitor2.process.statusCount": { ja: "{count}件", en: "{count} processes" },
  "wvMonitor2.process.lastUpdated": { ja: "前回更新: {time}", en: "Last updated: {time}" },
  "wvMonitor2.process.killedCount": { ja: "強制終了しました({count}件)", en: "Force-stopped ({count})" },
  "wvMonitor2.process.killFailed": { ja: "失敗: {error}", en: "Failed: {error}" },
  "wvMonitor2.process.running": { ja: "実行中…", en: "Running…" },

  // machineProfilesTab.js
  "wvMonitor2.common.remove": { ja: "除去", en: "Remove" },
  "wvMonitor2.machine.none": { ja: "(マシンプロファイルなし)", en: "(No machine profiles)" },
  "wvMonitor2.machine.deviceEmpty": {
    ja: "デバイスがありません。上のボタンから追加できます。",
    en: "No devices. You can add one from the button above.",
  },
  "wvMonitor2.machine.multiSelected": {
    ja: "{count}台選択中(右クリックで一括除去できます)",
    en: "{count} selected (right-click to remove them all)",
  },
  "wvMonitor2.machine.validation.nameRequired": {
    ja: "デバイス名を入力してください。",
    en: "Enter a device name.",
  },
  "wvMonitor2.machine.validation.nameExists": {
    ja: "「{name}」は既に存在します。",
    en: "\"{name}\" already exists.",
  },
  "wvMonitor2.machine.validation.portInvalid": {
    ja: "port は 0〜65535 の整数で入力してください。",
    en: "Enter port as an integer between 0 and 65535.",
  },
  "wvMonitor2.machine.updateFailed": {
    ja: "デバイスの更新に失敗しました。",
    en: "Failed to update the device.",
  },
  "wvMonitor2.machine.removeSelectedCount": {
    ja: "選択した{count}台を除去",
    en: "Remove {count} selected",
  },

  // appProfilesTab.js
  "wvMonitor2.appProfile.none": { ja: "アプリプロファイルがありません。", en: "No app profiles." },
  "wvMonitor2.appProfile.loadFailed": {
    ja: "アプリプロファイルを読み込めませんでした。",
    en: "Failed to load the app profile.",
  },
  "wvMonitor2.appProfile.saveFailed": {
    ja: "アプリプロファイルの更新に失敗しました。",
    en: "Failed to update the app profile.",
  },

  // laneLog.js
  "wvMonitor2.laneLog.selectedCount": { ja: "選択中{count}台を表示", en: "Showing {count} selected" },
  "wvMonitor2.laneLog.allWorkers": { ja: "全ワーカー", en: "All workers" },
  "wvMonitor2.laneLog.runFinished": {
    ja: "完了: 成功 {passed} / 失敗 {failed}",
    en: "Done: passed {passed} / failed {failed}",
  },
  "wvMonitor2.laneLog.timingTotal": { ja: "トータル {seconds}s", en: "Total {seconds}s" },
  "wvMonitor2.laneLog.timingTest": { ja: "テスト実時間 {seconds}s", en: "Test time {seconds}s" },
  "wvMonitor2.laneLog.timingScenarioTotal": {
    ja: "シナリオ合計 {seconds}s",
    en: "Scenario total {seconds}s",
  },

  // hostCharts.js
  "wvMonitor2.hostCharts.cpuTitle": { ja: "CPU負荷 {value}", en: "CPU load {value}" },
  "wvMonitor2.hostCharts.gpuTitle": { ja: "GPU負荷 {value}", en: "GPU load {value}" },
  "wvMonitor2.hostCharts.aneTitle": { ja: "ANE負荷 {value}", en: "ANE load {value}" },
  "wvMonitor2.hostCharts.wattsSuffix": { ja: "({watts}W)", en: "({watts}W)" },
  "wvMonitor2.hostCharts.memTitle": {
    ja: "メモリ使用量 {used} / {total} GB({percent})",
    en: "Memory usage {used} / {total} GB ({percent})",
  },
} satisfies MessageDict;
