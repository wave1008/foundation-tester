// CLI(英語のみ)が出すエラー文言の日本語訳。モニターのエラーバーが日本語 UI のとき
// 「原文【日本語訳】訳文」で出す(src/i18n/cliMessageTranslation.ts)。
//
// 契約:
// - **en は Swift の文言と1字一致**(照合の型そのもの)。{name} が補間 `\(...)` に対応する。
//   同じ名前を2回書くと「同じ値」を要求する。test/cliMessageTranslation.test.mjs が
//   Sources/FTBridgeClient の Swift と突き合わせる(Swift を変えたらここも直す)
// - 照合は部分一致の置換。入れ子(「…(port N): <下位のエラー>」)は下位の型も別の行として訳される
// - 訳せない文言は原文だけ出る(訳を付けないだけで壊れない)
import type { MessageDict } from "../core";

export const cliMessagesStrings = {
  // BridgeProvisionError(Sources/FTBridgeClient/BridgeProvisioner.swift)
  "cliMsg.provision.notReady": {
    en: "the bridge did not become ready in time (port {port})",
    ja: "ブリッジが時間内に準備完了になりませんでした (ポート {port})",
  },
  "cliMsg.provision.noFreePort": {
    en: "no free port (scanned {lower}-{upper}); every port in the bridge window is taken (a device can hold two: in-app and xcuitest). `fleetest bridge status` lists them, `fleetest doctor` names leftovers whose bridge is gone, and `fleetest bridge down --port <n>` frees one",
    ja: "空きポートがありません (走査 {lower}-{upper})。ブリッジ用のポート範囲がすべて使われています (1台のデバイスは in-app と xcuitest の2つを持てます)。`fleetest bridge status` で一覧、`fleetest doctor` でブリッジの無い残骸を確認でき、`fleetest bridge down --port <n>` で1つ空けられます",
  },
  "cliMsg.provision.inAppNeedsBundleID": {
    en: "starting an engine=inapp bridge requires the app bundleID. Set ios.app in the apps profile (paths that do not pass a bundleID, such as device/live, do not support engine=inapp)",
    ja: "engine=inapp のブリッジを起動するにはアプリの bundleID が必要です。アプリプロファイルに ios.app を設定してください (device/live のように bundleID を渡さない経路は engine=inapp に対応していません)",
  },
  "cliMsg.provision.appNotInstalled": {
    en: "{bundleID} is not installed, so this device drops out (engine=inapp requires it up front). Install it with `xcrun simctl install {udid} <app>`, or set appPath + autoInstall in the apps profile",
    ja: "{bundleID} がインストールされていないため、このデバイスを外します (engine=inapp では事前のインストールが必要です)。`xcrun simctl install {udid} <app>` でインストールするか、アプリプロファイルに appPath と autoInstall を設定してください",
  },
  "cliMsg.provision.deviceLocked": {
    en: "{name} stayed locked for {seconds}s. Unlock the device and run again (the runner cannot be launched on a locked device; once it is up it keeps the device awake, so this is only needed when the bridge is (re)built)",
    ja: "{name} が {seconds} 秒間ロックされたままでした。デバイスのロックを解除してもう一度実行してください (ロック中のデバイスではランナーを起動できません。起動後はデバイスをスリープさせないので、ブリッジを起動し直すときだけ必要です)",
  },
  "cliMsg.provision.preinstallFailed": {
    en: "automatic app install failed:",
    ja: "アプリの自動インストールに失敗しました:",
  },
  "cliMsg.provision.simulatorRebootFailed": {
    en: "rebooting the simulator failed:",
    ja: "Simulator の再起動に失敗しました:",
  },
  "cliMsg.provision.foreignBridgeInTheWay": {
    en: "the {reason} on port {port} belongs to another workspace ({owner}) — not stopping it, because that would break the other workspace's runs. Stop it from there (`fleetest bridge down --port {port}` in that workspace) and run again",
    ja: "ポート {port} の {reason} は別のワークスペース ({owner}) のものです。止めるとそのワークスペースの実行が壊れるので止めません。そちらで止めて (そのワークスペースで `fleetest bridge down --port {port}`) からもう一度実行してください",
  },
  // LauncherError(Sources/FTBridgeClient/BridgeLauncher.swift)
  "cliMsg.launcher.xctestrunNotFound": {
    en: "xctestrun not found (build-for-testing must run first):",
    ja: "xctestrun が見つかりません (先に build-for-testing が必要です):",
  },
  "cliMsg.launcher.notRunning": {
    en: "the bridge is not running (no {stem}.pid and no {stem}.inapp)",
    ja: "ブリッジは起動していません ({stem}.pid も {stem}.inapp もありません)",
  },
  "cliMsg.launcher.notOwnedByThisRepo": {
    en: "the bridge on port {port} is not managed by this repository ({target} / {version}). It does respond, so there is something to stop — **a bridge started by another clone or workspace**. Stop it from there, or kill the process from `lsof -ti :{port}` (on iOS, after stopping xcodebuild also run `xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner`)",
    ja: "ポート {port} のブリッジはこのリポジトリの管理下にありません ({target} / {version})。応答はしているので止める相手は居ます —— **別のクローンかワークスペースが起動したブリッジ**です。そちらで止めるか、`lsof -ti :{port}` のプロセスを kill してください (iOS では xcodebuild を止めた後に `xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner` も実行します)",
  },
  "cliMsg.launcher.timedOut": {
    en: "bridge start-up timed out (last error: {error}). Log: {log}",
    ja: "ブリッジの起動がタイムアウトしました (最後のエラー: {error})。ログ: {log}",
  },
  "cliMsg.launcher.portInUse": {
    en: "port {port} is in use by another process",
    ja: "ポート {port} は別のプロセスによって使用されています",
  },
  "cliMsg.launcher.developmentTeamMissing": {
    en: "building for a physical iOS device requires an Apple Developer Team ID. Set \"developmentTeam\" in ~/.config/fleetest/config.json or the FT_DEVELOPMENT_TEAM environment variable",
    ja: "iOS の実機向けビルドには Apple Developer の Team ID が必要です。~/.config/fleetest/config.json の \"developmentTeam\" か環境変数 FT_DEVELOPMENT_TEAM を設定してください",
  },
  "cliMsg.launcher.deviceRunnerElsewhere": {
    en: "physical device {device} already has an xcuitest runner (still starting, busy, or running) on port {port} (xcodebuild pid {pid}). A device runs one runner at a time — a second one kills the first. Use port {port} once it is ready, or stop it first with `fleetest bridge down --port {port}`",
    ja: "実機 {device} にはポート {port} の xcuitest ランナーが既にあります (起動中・処理中・実行中のいずれか。xcodebuild pid {pid})。1台のデバイスで動くランナーは1つだけで、2つ目は1つ目を落とします。準備ができたらポート {port} を使うか、先に `fleetest bridge down --port {port}` で止めてください",
  },
  "cliMsg.launcher.deviceRunnerElsewhereSimulator": {
    en: "simulator {device} already has an xcuitest runner (still starting, busy, or running) on port {port} (xcodebuild pid {pid}). A device runs one runner at a time — a second one kills the first. Use port {port} once it is ready, or stop it first with `fleetest bridge down --port {port}`",
    ja: "シミュレータ {device} にはポート {port} の xcuitest ランナーが既にあります (起動中・処理中・実行中のいずれか。xcodebuild pid {pid})。1台のデバイスで動くランナーは1つだけで、2つ目は1つ目を落とします。準備ができたらポート {port} を使うか、先に `fleetest bridge down --port {port}` で止めてください",
  },
  // PortHolder の占有者の説明(Sources/FTBridgeClient/PortHolder.swift)
  "cliMsg.portHolder.foreignInApp": {
    en: "another device's in-app bridge (udid {udid})",
    ja: "別のデバイスのアプリ内ブリッジ (udid {udid})",
  },
  "cliMsg.portHolder.foreignRunner": {
    en: "another device's xcuitest runner (udid {udid})",
    ja: "別のデバイスの xcuitest ランナー (udid {udid})",
  },
  "cliMsg.portHolder.usbTunnel": {
    en: "a physical device's USB tunnel (udid {udid})",
    ja: "実機の USB トンネル (udid {udid})",
  },
  "cliMsg.portHolder.notReleased": {
    en: " (the port is not released even after stopping)",
    ja: " (止めた後もポートが解放されません)",
  },
} satisfies MessageDict;
