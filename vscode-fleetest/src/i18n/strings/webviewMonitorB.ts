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
    ja: "参照するマシンプロファイルを指定してください。",
    en: "Specify the machine profile to reference.",
  },
  "wvMonitor2.runProfile.validation.machineNotFound": {
    ja: "マシンプロファイル「{machine}」が見つかりません。",
    en: "Machine profile \"{machine}\" was not found.",
  },
  "wvMonitor2.runProfile.validation.appRequired": {
    ja: "参照するアプリプロファイルを指定してください。",
    en: "Specify the app profile to reference.",
  },
  "wvMonitor2.runProfile.validation.deviceRequired": {
    ja: "デバイスを1台以上選択してください。",
    en: "Select at least one device.",
  },
  "wvMonitor2.runProfile.validation.timeoutInvalid": {
    ja: "defaultTimeout は正の数(秒)で入力してください。",
    en: "Enter defaultTimeout as a positive number (seconds).",
  },
  "wvMonitor2.runProfile.validation.wipeThresholdInvalid": {
    ja: "Wipe Data しきい値は正の数(GB)で入力してください。",
    en: "Enter the Wipe Data threshold as a positive number (GB).",
  },
  "wvMonitor2.runProfile.validation.recordBitrateInvalid": {
    ja: "ビットレートは正の整数(kbps)で入力してください。",
    en: "Enter the bitrate as a positive integer (kbps).",
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
  "wvMonitor2.process.lastUpdated": { ja: "前回更新: {time}", en: "Last updated: {time}" },

  // machineProfilesTab.js
  "wvMonitor2.common.remove": { ja: "除去", en: "Remove" },
  "wvMonitor2.machine.none": { ja: "(マシンプロファイルなし)", en: "(No machine profiles)" },
  "wvMonitor2.machine.deviceEmpty": {
    ja: "デバイスがありません。上のボタンから追加できます。",
    en: "No devices. You can add one from the button above.",
  },
  "wvMonitor2.machine.multiSelected": {
    ja: "{count}台選択中",
    en: "{count} selected",
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
  "wvMonitor2.machine.wipeData": { ja: "Wipe Data", en: "Wipe Data" },
  "wvMonitor2.machine.wipeSelectedCount": {
    ja: "選択した{count}台を Wipe Data",
    en: "Wipe Data on {count} selected",
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
  // 出力ペインの見出し。選択中は中身が実行ログではなく拡大した動画になるので言い換える
  // (静的HTML側の既定は panels.common.runLog。ja/en とも同じ文字列を保つこと)。
  "wvMonitor2.laneLog.titleRunLog": { ja: "実行ログ", en: "Run Log" },
  "wvMonitor2.laneLog.titleDevices": { ja: "デバイス", en: "Devices" },
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
  "wvMonitor2.hostCharts.lockOther": {
    ja: "{machine} で {issuer} の run が実行中",
    en: "A run by {issuer} is in progress on {machine}",
  },
  "wvMonitor2.hostCharts.lockMine": {
    ja: "{machine} で自分の run が実行中",
    en: "Your run is in progress on {machine}",
  },
  "wvMonitor2.hostCharts.lockIssuerUnknown": { ja: "誰か", en: "someone" },
  "wvMonitor2.hostCharts.cpuTitle": { ja: "CPU負荷 {value}", en: "CPU load {value}" },
  "wvMonitor2.hostCharts.gpuTitle": { ja: "GPU負荷 {value}", en: "GPU load {value}" },
  "wvMonitor2.hostCharts.fmTitle": {
    ja: "FM 呼び出し {total}回 / 計{totalSec}秒(直近1秒 {delta}回)",
    en: "FM calls {total} / {totalSec}s total (last 1s: {delta})",
  },
  "wvMonitor2.hostCharts.fmDeadLine": {
    ja: "✕ FM 全滅: {failures}回すべて失敗(偽陽性検証・自己修復・screenLooksLike はこの実行では無効)",
    en: "✕ FM dead: all {failures} calls failed (occlusion verify / heal / screenLooksLike are disabled in this run)",
  },
  "wvMonitor2.hostCharts.fmWarnLine": {
    ja: "⚠ FM 失敗 {failures}回 / 成功 {successes}回(失敗したステップのガードは素通り)",
    en: "⚠ FM failures {failures} / successes {successes} (guards on failed steps passed through)",
  },
  "wvMonitor2.hostCharts.memTitle": {
    ja: "メモリ使用量 {used} / {total} GB({percent})",
    en: "Memory usage {used} / {total} GB ({percent})",
  },
  // 設定タブ「更新」セクションの動的表示(settingsTab.js)。判定は Scripts/update-check.sh。
  // {reason} はスクリプトが出す英語(言語に関わらず英語。update-check.sh 冒頭の契約)
  "wvMonitor2.update.checking": { ja: "確認しています…", en: "Checking..." },
  "wvMonitor2.update.running": {
    ja: "更新中です(数分かかります。完了までウィンドウを閉じないでください)",
    en: "Updating (this takes a few minutes; keep this window open)",
  },
  "wvMonitor2.update.runningButton": { ja: "更新中…", en: "Updating..." },
  "wvMonitor2.update.upToDate": { ja: "最新です({local})", en: "Up to date ({local})" },
  "wvMonitor2.update.available": {
    ja: "更新があります({local} → {remote})",
    en: "Update available ({local} -> {remote})",
  },
  "wvMonitor2.update.pinned": {
    ja: "更新チェックの対象外です: {reason}",
    en: "Out of scope for update checks: {reason}",
  },
  "wvMonitor2.update.unavailable": {
    ja: "foundation-tester のクローンが見つからないため確認できません",
    en: "Cannot check: no foundation-tester clone found",
  },
  "wvMonitor2.update.unknown": { ja: "確認できませんでした: {reason}", en: "Could not check: {reason}" },

  // 設定タブ「リモート実行」セクションの動的表示(settingsTab.js。行を JS で組み立てるため
  // 静的ラベルの panels.settings.remote* と違いこちら側に置く。docs/remote-runner.md §12)。
  "wvMonitor2.remote.removeTitle": { ja: "このマシンを削除", en: "Remove this machine" },
  // マシン名は省略可。ホストが入っていればそこから採る名前を、空ならこの文言を出す
  // (規則は remoteRunArgs.ts の defaultMachineForHost)
  "wvMonitor2.remote.machinePlaceholder": {
    ja: "省略可(ホスト名 / IP)",
    en: "optional (host name / IP)",
  },
  "wvMonitor2.remote.syncFailed": {
    ja: "マシン登録簿への反映に失敗しました: {reason}",
    en: "Failed to save the machine registry: {reason}",
  },
} satisfies MessageDict;
