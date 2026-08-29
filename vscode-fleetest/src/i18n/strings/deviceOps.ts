// バッチE 辞書。namespace: deviceOps.
// 対象ソース: monitorDeviceOps.ts, residentProcesses.ts, monitorProcessManager.ts
// キーは "deviceOps." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const deviceOpsStrings = {
  "deviceOps.nameSeparator": { ja: "、", en: ", " },
  "deviceOps.nameListMore": { ja: "{shown} ほか", en: "{shown} and more" },

  "deviceOps.log.cancelBulkUpSigterm": {
    ja: "[fleetest] デバイスの起動を中断します(devices-up へ SIGTERM)",
    en: "[fleetest] Stopping device startup (sending SIGTERM to devices-up)",
  },
  "deviceOps.log.bulkUpQueueCancelled": {
    ja: "[fleetest] キュー待ちの一括起動を取り消しました",
    en: "[fleetest] Cancelled the queued bulk startup",
  },
  "deviceOps.log.devicesStartFailed": {
    ja: "[fleetest] devices {kind} の起動に失敗しました: {error}",
    en: "[fleetest] Failed to start devices {kind}: {error}",
  },
  "deviceOps.log.devicesRuntimeError": {
    ja: "[fleetest] devices {kind} の実行でエラーが発生しました: {error}",
    en: "[fleetest] An error occurred while running devices {kind}: {error}",
  },
  "deviceOps.log.devicesClosed": {
    ja: "[fleetest] devices {kind} が終了しました(exit code: {exitCode})",
    en: "[fleetest] devices {kind} finished (exit code: {exitCode})",
  },
  "deviceOps.log.unknownLine": {
    ja: "[{label}] 未知の形式の行を無視しました: {value}",
    en: "[{label}] Ignored a line with an unknown format: {value}",
  },
  "deviceOps.detailUnknown": { ja: "(詳細不明)", en: "(details unknown)" },
  "deviceOps.log.monitorRestartScheduled": {
    ja: "[monitor] 5秒後に自動再起動します",
    en: "[monitor] Restarting automatically in 5 seconds",
  },
  "deviceOps.log.monitorGaveUp": {
    ja: "[monitor] 起動直後の異常終了が3回続いたため自動再起動を停止しました(「モニター再起動」ボタンかパネルの開き直しで再挑戦できます)",
    en: "[monitor] Gave up automatic restarts after 3 consecutive early exits (retry with the restart button or by reopening the panel)",
  },
  "deviceOps.log.monitorClosed": {
    ja: "[monitor] プロセスが終了しました(exit code: {exitCode} / signal: {signal} / {initiated})。signal=SIGKILL は再ビルドによるバイナリ差し替えの署名",
    en: "[monitor] The process exited (exit code: {exitCode} / signal: {signal} / {initiated}). signal=SIGKILL is the signature of a rebuild replacing the binary",
  },
  "deviceOps.log.monitorHoldActive": {
    ja: "[monitor] fleetest monitor pause による保持中 — 観測と配信を停止しました(解除: fleetest monitor resume)",
    en: "[monitor] Held by fleetest monitor pause — observation and streaming stopped (release with: fleetest monitor resume)",
  },
  "deviceOps.log.monitorHoldReleased": {
    ja: "[monitor] 保持が解除されました — 観測を再開します",
    en: "[monitor] The hold was released — resuming observation",
  },
  "deviceOps.log.bulkOpFailed": {
    ja: "[fleetest] {label} が失敗しました: {error}",
    en: "[fleetest] {label} failed: {error}",
  },
  "deviceOps.log.devicesRestartStartFailed": {
    ja: "[fleetest] devices-restart の起動に失敗しました: {error}",
    en: "[fleetest] Failed to start devices-restart: {error}",
  },
  "deviceOps.log.devicesRestartFailed": {
    ja: "[fleetest] devices-restart が失敗しました: {error}",
    en: "[fleetest] devices-restart failed: {error}",
  },
  "deviceOps.log.devicesRestartRuntimeError": {
    ja: "[fleetest] devices-restart の実行でエラーが発生しました: {error}",
    en: "[fleetest] An error occurred while running devices-restart: {error}",
  },
  "deviceOps.log.devicesRestartClosed": {
    ja: "[fleetest] devices-restart が終了しました(exit code: {exitCode})",
    en: "[fleetest] devices-restart finished (exit code: {exitCode})",
  },
  "deviceOps.retryLabel": { ja: "(再試行 {attempt}/{max})", en: " (retry {attempt}/{max})" },
  "deviceOps.log.deviceOpFailed": {
    ja: "[fleetest] device-{op}({name})が失敗しました{attemptLabel}: {message}",
    en: "[fleetest] device-{op}({name}) failed{attemptLabel}: {message}",
  },
  "deviceOps.log.deviceUpRetrying": {
    ja: "[fleetest] device-up({name})を再試行します({nextAttempt}/{max}、{delayMs}ms 後)",
    en: "[fleetest] Retrying device-up({name}) ({nextAttempt}/{max}, after {delayMs}ms)",
  },
  "deviceOps.deviceOpFailedGeneric": { ja: "device-{op} に失敗しました。", en: "device-{op} failed." },
  // 実機のブリッジが署名で建たないときの案内。**判定は CLI**(FTBridgeClient の
  // XcodeSigningDiagnosis)で、文言はここが持つ(CLAUDE.md「共有するのは判定であって文言ではない」)。
  // **2行だけ**(ユーザー決定 2026-08-29): どこを直すか + 生ログの在り処。**直し方は書かない**
  // —— Xcode も macOS も版ごとに手順が変わり、書いた手順は必ず古くなる
  "deviceOps.signing.headline": {
    ja: "実機用のブリッジに署名できません。その端末が繋がっている Mac の Xcode の署名設定を直してから、"
      + "もう一度ブリッジを起動してください。",
    en: "Cannot code-sign the bridge runner for a physical device. Fix Xcode's signing setup on the Mac"
      + " that the device is connected to, then start the bridge again.",
  },
  "deviceOps.signing.fullLog": {
    ja: "xcodebuild の全出力: {path}",
    en: "Full xcodebuild output: {path}",
  },
  "deviceOps.log.deviceOpClosed": {
    ja: "[fleetest] device-{op}({name})が終了しました{attemptLabel}(exit code: {exitCode})",
    en: "[fleetest] device-{op}({name}) finished{attemptLabel} (exit code: {exitCode})",
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
  // stderr に原因と対処が出ているとき(リモート転送の失敗など)は必ずそれを添える。
  // detail は CLI 由来なので英語のまま(枠だけ訳す。reason= と同じ規律)。
  "deviceOps.cmdFailedExitCodeDetail": {
    ja: "{cmd} が失敗しました(exit code: {exitCode}): {detail}",
    en: "{cmd} failed (exit code: {exitCode}): {detail}",
  },
  "deviceOps.cmdParseFailed": {
    ja: "{cmd} の出力を解析できませんでした: {error}",
    en: "Failed to parse {cmd} output: {error}",
  },
  "deviceOps.cmdOutputInvalid": { ja: "{cmd} の出力形式が不正です。", en: "{cmd} output format is invalid." },
  // §13 段2「マシン」セレクタ: リモート実行時のエラーへマシン名を付記する(withSourceContext)。
  "deviceOps.remoteMachineSuffix": { ja: "{message}(マシン: {machine})", en: "{message} (machine: {machine})" },
  "deviceOps.createRemoteConfirmMessage": {
    ja: "「{name}」を {machine} 上に作成します。よろしいですか?",
    en: "This creates \"{name}\" on {machine}. Continue?",
  },
  "deviceOps.createRemoteConfirmButton": { ja: "作成", en: "Create" },
  // 同名の実体があるときの上書き確認。**削除を伴う**ので、消える対象と機械を文中に出す
  "deviceOps.createOverwriteConfirmMessage": {
    ja: "{machine} の「{name}」は既に存在します。削除して作り直しますか?(元に戻せません)",
    en: "\"{name}\" already exists on {machine}. Delete it and create it again? (cannot be undone)",
  },
  "deviceOps.createOverwriteConfirmButton": { ja: "削除して作り直す", en: "Delete and recreate" },
  "deviceOps.createOverwriteLocalMachine": { ja: "このマシン", en: "this machine" },
  // exit 64 = 引数エラー。リモートで出たら「向こうの fleetest が古い」がほぼ唯一の原因
  "deviceOps.remoteCliTooOld": {
    ja: "{machine} の fleetest がこの操作に対応していません(版が古い可能性があります)。{machine} で版を揃えてください: fleetest remote setup {machine} — {detail}",
    en: "The fleetest on {machine} does not support this operation (it is probably out of date). Align it with: fleetest remote setup {machine} — {detail}",
  },
  "deviceOps.createCancelled": { ja: "作成をキャンセルしました。", en: "Device creation was cancelled." },
  // バッチ作成の確認(webview の window.confirm は効かないのでホスト側 modal で聞く)。
  // **1枚だけ**出す —— 上書きが要るときは batchOverwriteNote を同じ文面へ書き足す
  "deviceOps.batchConfirmMessage": {
    ja: "{machine} に {count} 台のデバイスを作成します({first} 〜 {last})。よろしいですか?",
    en: "This creates {count} devices on {machine} ({first} - {last}). Continue?",
  },
  "deviceOps.batchConfirmButton": { ja: "作成", en: "Create" },
  // **確認ダイアログ1枚に書き足す文**(別のダイアログにしない)。先頭の改行は本文と離すため
  "deviceOps.batchOverwriteNote": {
    ja: "\n\nうち {count} 台は {machine} に既に存在します({names})。削除して作り直します(元に戻せません)。",
    en: "\n\n{count} of them already exist on {machine} ({names}) and will be deleted and recreated (cannot be undone).",
  },
  "deviceOps.batchOverwriteConfirmButton": { ja: "削除して作り直す", en: "Delete and recreate" },
  "deviceOps.batchAlreadyRunning": {
    ja: "デバイスの作成が実行中です。",
    en: "A create operation is already in progress.",
  },

  "deviceOps.createAlreadyRunning": {
    ja: "作成処理が既に実行中です。",
    en: "A create operation is already in progress.",
  },
  "deviceOps.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。fleetest.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the fleetest.project setting.",
  },
  "deviceOps.log.createDeviceStartFailed": {
    ja: "[fleetest] create-device({name})の起動に失敗しました: {error}",
    en: "[fleetest] Failed to start create-device({name}): {error}",
  },
  "deviceOps.log.createDeviceFailed": {
    ja: "[fleetest] create-device({name})が失敗しました: {error}",
    en: "[fleetest] create-device({name}) failed: {error}",
  },
  "deviceOps.log.createDeviceRuntimeError": {
    ja: "[fleetest] create-device({name})の実行でエラーが発生しました: {error}",
    en: "[fleetest] An error occurred while running create-device({name}): {error}",
  },
  "deviceOps.log.createDeviceClosed": {
    ja: "[fleetest] create-device({name})が終了しました(exit code: {exitCode})",
    en: "[fleetest] create-device({name}) finished (exit code: {exitCode})",
  },

  "deviceOps.machineLocalLabel": { ja: "ローカル", en: "the local machine" },
  // **台数も名前も入れない**(10台選ぶと名前だけで数行になり、肝心の「消える」が埋もれる)。
  // 対象は右ペインの選択状態が示している。
  "deviceOps.wipeConfirmMessage": {
    ja: "選択したデバイスのデータを消去します。よろしいですか?",
    en: "This wipes the data on the selected devices. Continue?",
  },
  "deviceOps.wipeConfirmDetail": {
    ja:
      "インストール済みアプリ・設定・保存データがすべて消えます(元に戻せません)。" +
      "起動中のデバイスは停止してから消去し、そのあと起動し直します(Android は初回起動の再構築で数分かかります)。",
    en:
      "Installed apps, settings and saved data are all removed (this cannot be undone). " +
      "Running devices are stopped before the wipe and started again afterwards " +
      "(on Android the first boot rebuilds and takes minutes).",
  },
  "deviceOps.wipeConfirmButton": { ja: "Wipe Data", en: "Wipe Data" },
  "deviceOps.wipeAllBusy": {
    ja: "対象のデバイスはすべて別の操作を実行中です。完了してからやり直してください。",
    en: "Every selected device already has an operation in progress. Try again once it finishes.",
  },
  "deviceOps.log.wipeSkippedBusy": {
    ja: "[fleetest] {name}は別の操作を実行中のため Wipe Data を見送りました",
    en: "[fleetest] Skipped Wipe Data for {name}: another operation is already in progress",
  },
  "deviceOps.deleteConfirmMessage": {
    ja: "「{name}」を {machine} から削除します。シミュレータ/AVD本体が削除されるため、元に戻せません。よろしいですか?",
    en: "This deletes \"{name}\" from {machine}. It removes the underlying simulator/AVD and cannot be undone. Continue?",
  },
  "deviceOps.deleteConfirmButton": { ja: "削除", en: "Delete" },
  "deviceOps.deleteCancelled": { ja: "削除をキャンセルしました。", en: "Device deletion was cancelled." },
  "deviceOps.deleteAlreadyRunning": {
    ja: "削除処理が既に実行中です。",
    en: "A delete operation is already in progress.",
  },
  "deviceOps.deleteFailedGeneric": { ja: "デバイスの削除に失敗しました。", en: "Failed to delete the device." },
  "deviceOps.deleteReferencedByWarning": {
    ja:
      "「{name}」を削除しました。これを参照しているマシンプロファイルが残っています: {profiles}。" +
      "次回の実行前に該当プロファイルのデバイス設定を見直してください。",
    en:
      "Deleted \"{name}\". The following machine profiles still reference it: {profiles}. " +
      "Review their device settings before the next run.",
  },
  "deviceOps.log.deleteDeviceStartFailed": {
    ja: "[fleetest] delete-device({name})の起動に失敗しました: {error}",
    en: "[fleetest] Failed to start delete-device({name}): {error}",
  },
  "deviceOps.log.deleteDeviceUnregistered": {
    ja: "[fleetest] {name}をマシンプロファイルから外しました: {profiles}",
    en: "[fleetest] Unregistered {name} from machine profile(s): {profiles}",
  },
  "deviceOps.log.deleteDeviceSucceeded": {
    ja: "[fleetest] delete-device({name})が完了しました。",
    en: "[fleetest] delete-device({name}) finished.",
  },
  "deviceOps.log.deleteDeviceFailed": {
    ja: "[fleetest] delete-device({name})が失敗しました: {error}",
    en: "[fleetest] delete-device({name}) failed: {error}",
  },
  "deviceOps.log.deleteDeviceRuntimeError": {
    ja: "[fleetest] delete-device({name})の実行でエラーが発生しました: {error}",
    en: "[fleetest] An error occurred while running delete-device({name}): {error}",
  },
  "deviceOps.log.deleteDeviceClosed": {
    ja: "[fleetest] delete-device({name})が終了しました(exit code: {exitCode})",
    en: "[fleetest] delete-device({name}) finished (exit code: {exitCode})",
  },

  "deviceOps.log.monitorStartFailed": {
    ja: "[fleetest] monitor プロセスの起動に失敗しました: {error}",
    en: "[fleetest] Failed to start the monitor process: {error}",
  },
  "deviceOps.monitorStartFailedMessage": {
    ja: "モニタープロセスの起動に失敗しました: {error}",
    en: "Failed to start the monitor process: {error}",
  },
  "deviceOps.log.monitorRuntimeError": {
    ja: "[fleetest] monitor プロセスでエラーが発生しました: {error}",
    en: "[fleetest] An error occurred in the monitor process: {error}",
  },
  "deviceOps.monitorExitedUnexpectedHint": {
    ja: "予期せず終了しました。「モニター再起動」で再開できます。",
    en: "It exited unexpectedly. You can restart it with \"Restart Monitor\".",
  },
  "deviceOps.monitorExitedMachineHint": {
    ja:
      "マシンプロファイル未設定の可能性があります。TestProjects/<project>/profiles/machines/ の " +
      "内容と、実行プロファイルの machine を確認してください。",
    en:
      "The machine profile might not be configured. Check TestProjects/<project>/profiles/machines/ " +
      "and the run profile's machine.",
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
