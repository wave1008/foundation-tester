// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。
//
// - `ftester api monitor --project <P> --interval <秒> --max-width <px> [--profile <run>]` を
//   自前で spawn し(--profile は ftester.profile 設定が非空のときのみ付与。指定時はそのプロファイルが
//   参照するデバイスのみに監視対象を絞り込む)、NdjsonParser(vscode 非依存)でパース →
//   monitorModel.ts(同じく vscode 非依存)で検証・変換した上で webview.postMessage する。
//   cli.ts の FtesterCli(直列実行キュー)は使わない — monitor は接続中ずっと動き続けるプロセスなので、
//   キューに載せると以後の実行・ステップ取得等の CLI 呼び出しが永久にブロックされてしまうため。
// - パネルはシングルトン(既に開いていれば reveal するだけ)。
// - パネル破棄・拡張 deactivate 時は子プロセスに SIGTERM を送り、2秒後もまだ生きていれば
//   SIGKILL する(cli.ts の cancelCurrent() と同じ方針)。
// - webview からの devicesUp/devicesDown も cli.ts のキューは使わず、ここで直接
//   短命プロセス(`ftester devices up`/`devices down`)を spawn する。ftester.profile が非空なら
//   --project/--profile を付与し、「デバイスを全て起動/終了」の対象をそのプロファイルが参照する
//   デバイスのみに限定する(空ならマシンプロファイルの全デバイス。要件1)。多重起動ガードのため
//   実行中は bootBusy:true を webview に送ってボタンを無効化させる。
// - プロファイル切り替え時の自動シャットダウン(要件2): restartMonitorIfScopeChanged() が
//   ftester.profile / ftester.project の変更でスコープが変わったことを検知すると、モニター再起動の
//   前に、直近の観測(lastKnownDevices)から「切り替え先プロファイルに定義されていない稼働中
//   デバイス」を割り出し(monitorModel.ts の devicesToShutdownOnScopeChange)、device-down ジョブを
//   キューに積む。定義されているデバイスは稼働中でもそのまま(自動起動はしない)。
// - ログレーン表示: RunEventBus(runHandler.ts の実行と同じインスタンスを extension.ts から
//   注入される)を購読し、`ftester api run` の生イベントを runLaneModel.ts(vscode/webview
//   非依存の純粋関数)でレーン用アクションに変換して webview へ転送する。デバイスタイルと
//   ログレーンは device id / worker id が同一規則なので、そのまま突合できる
//   (タイルの「実行中」バッジ・タイル選択によるレーン絞り込み)。
// - webview はマルチタブ構成(「デバイス」「プロファイル」「設定」)。既存のデバイスモニターUI
//   一式(トップの操作)はそのまま「デバイス」タブのパネル内に移動しただけで、TypeScript 側の
//   ロジックは変わらない。「設定」は現状プレースホルダーのみで、今後の機能追加先。
// - 「プロファイル」タブの3セクションは DOM 順で上から実行/アプリ/マシンプロファイル(使用
//   頻度が高い実行プロファイルを先頭にしてほしいというユーザー報告により、以前のマシン/アプリ/
//   実行の順から並べ替えた。各セクションの内部構造・JS ロジックは不変)。#panel-profiles の
//   先頭(全セクションの前)には position: sticky なジャンプヘッダー(#profile-jump-header)を
//   常設し、3セクションへのテキストリンク(button 要素)から scrollIntoView({behavior:'smooth'})
//   で各セクションへ飛べるようにする(単一の縦スクロールになったことで下のセクションまで
//   長くスクロールする必要が出たため)。sticky ヘッダーの裏に見出しが隠れないよう、各
//   .profile-section に scroll-margin-top を設定する。
// - 「プロファイル」タブの「マシンプロファイル」セクション: Projects/<project>/profiles/machines/
//   直下の *.json(config.ts の listMachineProfiles)を一覧表示する。デバイス追加の入口は
//   「デバイス」ラベル横の「+」(#btn-device-add-existing)の1つだけ(2026-07-11 指示で
//   「+新規作成」ボタンは廃止。新規作成は選択画面内の「+」から行う。`ftester api device-catalog`
//   (単発 JSON)/`ftester api create-device`(NDJSON)は新規作成モーダルが引き続き使う)。「+」は
//   #device-pick-overlay モーダルを開き、`ftester api installed-devices`(単発 JSON。runInstalledDevices)
//   でインストール済みの実体一覧を取得して2列(iOS/Android)で一覧表示する。各行のチェックボックスは
//   「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表す設計(disabled/淡色化は廃止)。
//   初期状態は udid(iOS)/avd の id または displayName(Android)で現在の登録済みデバイスと突合し、
//   登録済みなら初期チェック、未登録なら初期未チェックにする。OK は行ごとの初期状態からの差分が
//   1件以上あるときだけ有効になり、押下時に差分(新たにチェック=追加/外した=登録解除)だけを
//   machineDevicesSync(add/remove)としてまとめて送る(モーダル確認は挟まず、チェック操作自体を
//   確定操作として扱う。ホスト側の syncDevicesInMachineProfile が
//   removeDeviceFromMachineProfile→addDevicesToMachineProfile の順で合成する純粋関数部分を担当。
//   削除を先に行うのは、外して同名で付け直すケースで名前衝突の自動サフィックスが誤発動しない
//   ようにするため)。モーダル下部には「チェックを外して OK すると登録解除されます(シミュレータ/
//   AVD 本体は削除されません)」という常設の注記を置き、誤操作への注意を促す。タイトル行右端の
//   「+」ボタン(#device-pick-add-new)は #device-pick-overlay を閉じずに #device-add-overlay
//   (「+新規作成」モーダル)をその上に重ねて開く(z-index を #device-pick-overlay より高くして
//   スタック表示)。#device-add-overlay はフルスクリーンのオーバーレイなので、ピッカーから開いたか
//   どうかは openDeviceAddModal() 呼び出し時点の devicePickOpen(deviceAddFromPicker に記録)で
//   判定できる。この経路(deviceAddFromPicker=true)では createDevice に register:false を送り、
//   ホストは `--no-register` を付けて物理作成のみ行う(マシンプロファイルへは追記しない。
//   register:true の即登録経路はメッセージ契約として残っているが、「+新規作成」ボタン廃止後は
//   UI からの送り手がいない。2026-07-11 指示)。register:false の作成が成功したら、
//   installedDevicesRequest を再送して一覧を作り直す前に pendingAutoCheck へ作成された実体の
//   識別子(iOS=udid/Android=avd の id。createDeviceResult の device フィールドから取る)を保持し、
//   再描画時に一致する行を「チェックON」(初期状態[registered]は false のままなので差分扱い)にする。
//   これにより新規デバイスは「未登録+チェックON」の状態で現れ、OK ボタンが有効になり、押下すると
//   machineDevicesSync の add 経由でマシンプロファイルへ登録される(=「OK で登録」を実現する)。
//   一致する行が見つからない場合は pendingAutoCheck を静かに捨てて何もしない。他行で操作中だった
//   未確定の差分は(register:true 経路と同じく)この再読込で破棄されるが、シンプルさを優先した
//   設計判断。いずれも他の短命 CLI 実行(executeBulkJob 等)と同じく直接 spawn する方針
//   (FtesterCli の直列キューは使わない)。デバイス一覧は複数選択に対応する(要件5。
//   selectedDeviceNames が Set。通常クリックは単一選択への置き換え[トグル]、Shift+クリックは
//   アンカー(直近に通常/Cmdクリックした行)からの範囲選択、Cmd/Ctrl+クリックは個別の追加/除外
//   トグル。Finder/VSCode のリストと同じ標準セマンティクス。2026-07-11 ユーザー指示)。
//   右ペインの編集フォームは「ちょうど1台選択」のときだけ表示する。
//   デバイス行の右クリック「除去」/「選択した<N>台を除去」(handleMachineDeviceRemove。複数選択に
//   対応するため machineDeviceRemove の対象は names 配列)・行選択時に右ペインに表示する編集フォーム
//   の「確定」(handleMachineDeviceUpdate)はいずれも CLI を呼ばず、machines/<machine>.json を
//   直接読み書きする(monitorModel.ts の removeDeviceFromMachineProfile / updateDeviceInMachineProfile
//   が純粋関数部分を担当)。マシンプロファイル自体の追加/コピー/削除/名前変更(マシン名横の
//   アイコンボタン。handleMachineProfileAdd/Copy/Delete/Rename)も同様に CLI を呼ばず
//   machines/*.json を直接読み書きする。名前変更時は CLI 登録名(~/.config/ftester/config.json の
//   machineName)が旧名のままだと解決が壊れるため、config.ts の updateLocalMachineName で追随させる。
// - 「プロファイル」タブ上段の「実行プロファイル」セクション: runs/<name>.json の内容を編集する
//   フォーム。一覧・初期選択は既存の profileInfo(デバイスタブのドロップダウンと共用。apps を
//   追加しただけ)を流用するが、この選択(編集対象)は ftester.profile 設定とは独立
//   (selectProfile とは別に webview 内だけで完結する)。ロード(runProfileLoad)/保存
//   (runProfileSave)はいずれも CLI を呼ばず、runs/<name>.json を直接読み書きする
//   (monitorModel.ts の parseRunProfileForForm/updateRunProfileInObject が純粋関数部分を担当。
//   removeDeviceFromMachineProfile/updateDeviceInMachineProfile と同じ、未知キー保持の
//   イミュータブル更新の方針)。dirty 管理・machineProfileInfo/profileInfo 再受信時の再プリフィル
//   可否も、右ペインのデバイス編集フォーム(machineDeviceUpdate)と同じ方針(dirty/送信中は保持、
//   そうでなければ再描画)。profileFileWatcher の onDidChange(今回追加)で外部編集も検知し、
//   編集中でなければ自動的に再ロードする。実行プロファイル自体の追加/コピー/削除/名前変更
//   (セクションヘッダーのアイコンボタン。handleProfileAdd/Copy/Delete/Rename)も、マシンプロファイル
//   の [+][コピー][−][✏] と同一デザイン・同じ対話形式(名前入力はwebview内モーダル
//   [#name-input-overlay]、削除確認はshowWarningMessageのモーダル確認)で行う
//   (以前はデバイスタブのツールバーに置いていたが、下半分のフォームが編集手段になったのに合わせて
//   ここへ移設し、デバイスタブは実行プロファイルの選択のみに絞った)。追加・コピー直後は
//   runProfileSelected で編集対象を新プロファイルへ移す(machineProfileSelected と同じ方式。
//   削除は webview 側の既存フォールバックに任せるので送らない)。名前変更時、ftester.profile が
//   旧名を指していたら selectProfile で追随させる(handleMachineProfileRename の
//   updateLocalMachineName 追随と同じ理由)。
// - 「プロファイル」タブ中段の「アプリプロファイル」セクション: apps/<name>.json(common/ios/android
//   の3セクション)を編集するフォーム。common は表示名(appName)+自動インストール(autoInstall。
//   チェックボックス1つで有効/無効の2値、既定=無効[チェックOFF])の2フィールド、ios/android は
//   表示名/アプリID(app)/パッケージパス(appPath)の3フィールド(common の app/appPath は廃止済み
//   でランタイムはこれらの値を無視するためフォーム自体に入力欄を持たない。自動インストールは
//   元々 ios/android セクション別だったが、common でのみ設定できる仕様に一本化した
//   [2026-07-11 指示。Swift 側も common 採用+platform 残存は validate 警告に変更中])。設計は
//   実行プロファイルセクションの複製(選択は webview 内だけで完結する独立状態。ただし「現在値」に
//   相当する設定が無いため、選択のフォールバックは常に一覧の先頭)。
//   ロード(appProfileLoad)/保存(appProfileSave)は monitorModel.ts の
//   parseAppProfileForForm/updateAppProfileInObject が純粋関数部分を担当する(未知キー保持の
//   イミュータブル更新。既存の空セクションはそのまま保持し、元に無いセクションは値が1つでも
//   入力されない限り作らない。autoInstall は既定=無効[false]なので「無効」を選んだだけでは
//   「値あり」に数えない)。追加/コピー/削除/名前変更(handleAppProfileAdd/Copy/
//   Delete/Rename)も実行プロファイル版の複製だが、アプリプロファイルは ftester.* のどの設定からも
//   直接参照されないため、削除・名前変更時に追随させる設定は無い(実行プロファイルの app 参照が
//   古い名前を指したままになりうるが、そちらは CLI 側の validate-profile が検出する領分とし、
//   この拡張からは追随しない)。appsFileWatcher(今回追加)の onDidChange で外部編集も検知する。
// - ホストMacのメトリクスグラフ(CPU/GPU/ANE/MEM。デバイスタブの #toolbar、実行プロファイル選択
//   [.profile-label]の直後に4つ横並びで表示): `ftester api host-metrics --interval 1` を monitor
//   プロセスとは別に常駐 spawn し(startHostMetricsProcess/stopHostMetricsProcess。stdin をパイプで
//   保持したまま EOF で終了させる・SIGTERM 送信後2秒待って SIGKILL、という流儀は monitor プロセスの
//   管理[startMonitorProcess/stopMonitorProcess]と同じ)、NdjsonParser(monitor と共用)で受けた
//   `{"kind":"hostMetrics", ...}` 行を isHostMetricsEvent で検証してから webview へ `hostMetrics`
//   メッセージとして転送する。host-metrics はプロファイル/プロジェクトに依存しない(ホストMac自体の
//   値なので、restartMonitorIfScopeChanged 等の監視対象切り替えでは再起動しない)。予期しない終了時は
//   パネルが生きていれば5秒後に自動再起動するが(scheduleHostMetricsRestart)、起動後10秒未満での
//   異常終了が3回連続したら諦めて outputChannel に1回だけログし、以後は自動再起動を止める
//   (hostMetricsGaveUp。旧バイナリに host-metrics サブコマンドが無い環境で無限に再起動ループしない
//   ようにするための安全弁)。「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")は
//   この失敗カウンタもリセットして再起動を試みるので、バイナリ更新後はボタン一つで復帰できる
//   (パネルを開き直したとき[show()]も同様にリセットする)。webview 側はグラフ描画用の独自タイマーを
//   持たず、host-metrics プロセスの1秒 interval で届く hostMetrics メッセージ受信のたびに直近60
//   サンプルのローリングバッファへ追加して canvas に再描画するだけ(CPU/GPU/ANE は 0..1 の負荷率、
//   MEM は memUsedBytes/memTotalBytes の比率。いずれも null は欠測として線を途切れさせる)。系列色は
//   ライト/ダークテーマで切り替える固定パレットを使い、body の class(vscode-light 等)の変化を
//   MutationObserver で監視して即座に全グラフを再描画する。
// - webview 資産(スタイル・スクリプト)は src/webview/monitor/{style.css,main.js} に分離されている
//   (Phase 1: webview 資産の実ファイル化。以前は renderHtml() のテンプレート文字列に CSS/JS を
//   直接内蔵していた)。esbuild(esbuild.mjs の buildWebview())がこれらを media/monitor/ に
//   バンドルし、renderHtml() は webview.asWebviewUri で変換した URI を使って
//   <link rel="stylesheet">/<script src> から外部リソースとして読み込む。HTML 本文は今回は
//   移動しておらず、引き続き renderHtml() 内にインラインで生成する(次フェーズで分離予定)。

import * as fs from "node:fs";
import * as path from "node:path";
import { randomBytes } from "node:crypto";
import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import * as vscode from "vscode";
import {
  type FtesterConfig,
  listAppProfileNames,
  listMachineProfiles,
  listRunProfileNames,
  type MachineProfileSummary,
  readLocalMachineName,
  readMachineDeviceNames,
  readRunProfileDeviceNames,
  resolveProjectName,
  updateLocalMachineName,
} from "./config";
import {
  type AppProfileFormFields,
  buildRunProfileTemplate,
  createDeviceLifecycleQueueState,
  dequeueDeviceLifecycleJob,
  type DeviceLifecycleJob,
  type DeviceLifecycleQueueState,
  deviceLifecycleJobNeedsMonitorPause,
  deviceLifecycleQueueHead,
  deviceLifecycleStatusFor,
  type DeviceOpKind,
  devicesToShutdownOnScopeChange,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isCreateDeviceEvent,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isInstalledDevicesJson,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  machineDeviceDetail,
  type MonitorControlCommand,
  monitorControlLine,
  type MonitorDevice,
  type MonitorFromWebviewMessage,
  parseAppProfileForForm,
  parseRunProfileForForm,
  removeDeviceFromMachineProfile,
  syncDevicesInMachineProfile,
  toWebviewMessage,
  type MonitorToWebviewMessage,
  type RunProfileFormFields,
  updateAppProfileInObject,
  updateDeviceInMachineProfile,
  updateRunProfileInObject,
  validateNewAppProfileName,
  validateNewMachineProfileName,
  validateNewRunProfileName,
} from "./monitorModel";
import { NdjsonParser } from "./ndjson";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";

const VIEW_TYPE = "ftesterMonitor";
const PANEL_TITLE = "ftester デバイスモニター";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts の FtesterProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** webview からの "createDevice" メッセージの形(handleWebviewMessage/runCreateDevice で使う)。 */
type CreateDeviceMessage = Extract<MonitorFromWebviewMessage, { type: "createDevice" }>;

/** webview からの "machineDeviceUpdate" メッセージの形(handleMachineDeviceUpdate で使う)。 */
type MachineDeviceUpdateMessage = Extract<MonitorFromWebviewMessage, { type: "machineDeviceUpdate" }>;

/** webview からの "machineDevicesSync" メッセージの形(handleMachineDevicesSync で使う)。 */
type MachineDevicesSyncMessage = Extract<MonitorFromWebviewMessage, { type: "machineDevicesSync" }>;

/** webview からの "runProfileSave" メッセージの形(handleRunProfileSave で使う)。 */
type RunProfileSaveMessage = Extract<MonitorFromWebviewMessage, { type: "runProfileSave" }>;

/** webview からの "appProfileSave" メッセージの形(handleAppProfileSave で使う)。 */
type AppProfileSaveMessage = Extract<MonitorFromWebviewMessage, { type: "appProfileSave" }>;

/**
 * monitor プロセス用: stdin もパイプで保持する。
 * `ftester api monitor` は stdin の EOF を終了指示として扱うため、stdio を "ignore"(=/dev/null)
 * にすると起動直後に EOF を検知して即終了してしまう(タイルが一切表示されない症状の原因)。
 */
type MonitorProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/**
 * host-metrics プロセス(`ftester api host-metrics --interval 1`)が stdout に流す1行の形。
 * monitor とは別プロセス・別スキーマなので monitorModel.ts の MonitorEvent 側には混ぜず、ここで
 * 直接定義・検証する(isMonitorEvent と同じ「壊れた行は安全側で無視する」方針)。
 */
type HostMetricsRawEvent = {
  readonly kind: "hostMetrics";
  readonly ts: number;
  readonly cpu: number | null;
  readonly gpu: number | null;
  readonly ane: number | null;
  readonly aneWatts: number | null;
  readonly memUsedBytes: number | null;
  readonly memTotalBytes: number | null;
};

/** value が HostMetricsRawEvent として扱ってよいか判定する(isMonitorEvent と同じ方針)。 */
function isHostMetricsEvent(value: unknown): value is HostMetricsRawEvent {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const record = value as Record<string, unknown>;
  const numberOrNull = (field: unknown): boolean => field === null || typeof field === "number";
  return (
    record.kind === "hostMetrics" &&
    typeof record.ts === "number" &&
    numberOrNull(record.cpu) &&
    numberOrNull(record.gpu) &&
    numberOrNull(record.ane) &&
    numberOrNull(record.aneWatts) &&
    numberOrNull(record.memUsedBytes) &&
    numberOrNull(record.memTotalBytes)
  );
}

/** host-metrics プロセスの1サンプルを webview へ送るメッセージの形(post() 経由)。 */
type HostMetricsToWebviewMessage = {
  readonly type: "hostMetrics";
  readonly cpu: number | null;
  readonly gpu: number | null;
  readonly ane: number | null;
  readonly aneWatts: number | null;
  readonly memUsedBytes: number | null;
  readonly memTotalBytes: number | null;
};

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = new MonitorPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
  );
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showDeviceMonitor", () => controller.show()),
  );
}

/**
 * 確認モーダルに列挙する対象デバイス名の文字列(「、」区切りで最大3件+超過分は「 ほか」)。
 * handleMachineDeviceRemove の複数選択一括除去の確認文言で使う。
 */
function summarizeDeviceNames(names: readonly string[]): string {
  const shown = names.slice(0, 3).join("、");
  return names.length > 3 ? `${shown} ほか` : shown;
}

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private monitorProcess: MonitorProcess | undefined;
  /** stopMonitorProcess() 経由(dispose/再起動)による意図した終了かどうか。 */
  private stoppingMonitor = false;
  /**
   * 現在の monitor プロセスが実際に使っている監視スコープ("<project> <profile>" 形式。
   * profile が空なら "<project> ")。ftester.profile / ftester.project の変更を検知したときに、
   * 監視対象を変えるべきかどうか(=再起動が必要かどうか)を判定するために保持する。
   */
  private monitorScope: string | undefined;
  /**
   * restartMonitorProcess() の多重起動ガード。true の間は追加の再起動要求を無視する。
   * 連続したプロファイル変更や「モニター再起動」ボタン連打で stopMonitorProcess() →
   * startMonitorProcess() が重なり、monitor プロセスが二重起動するのを防ぐ。
   */
  private restartPending = false;
  /** host-metrics プロセス(常駐。monitor プロセスとは独立に管理する)。 */
  private hostMetricsProcess: MonitorProcess | undefined;
  /** stopHostMetricsProcess() 経由による意図した終了かどうか(stoppingMonitor と同じ役割)。 */
  private stoppingHostMetrics = false;
  /** restartHostMetricsProcess() の多重起動ガード(restartPending と同じ役割)。 */
  private hostMetricsRestartPending = false;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/stop 時に必ずクリアする。 */
  private hostMetricsRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private hostMetricsStartedAt: number | undefined;
  /**
   * 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める
   * (旧バイナリに host-metrics サブコマンドが無い環境で無限に再起動ループしないための安全弁)。
   * 10秒以上動いてからの終了は正常運転とみなして 0 にリセットする。
   */
  private hostMetricsFailureStreak = 0;
  /**
   * 自動再起動を諦めた状態かどうか。true の間は close イベントで再起動をスケジュールしない。
   * 「モニター再起動」ボタン(handleWebviewMessage の "restartMonitor")でリセットして再挑戦できる
   * (バイナリ更新後の復帰経路)。パネルを開き直したとき(show())も同様にリセットする。
   */
  private hostMetricsGaveUp = false;
  /**
   * 直近の monitorDevices イベントで観測したデバイス一覧(state 込み)。モニタープロセスの再起動
   * (プロファイル切り替え含む)を跨いで保持し、リセットしない — restartMonitorIfScopeChanged() が
   * 「切り替え直前(旧スコープ)の最終観測」を元に、新スコープ外の稼働中デバイスを判定する
   * (devicesToShutdownOnScopeChange)ために必要なため。新しい monitor プロセスが起動して
   * 最初の monitorDevices を出すまでの間も、直前の観測を保持し続ける。
   */
  private lastKnownDevices: readonly MonitorDevice[] = [];
  /**
   * デバイスライフサイクル操作(「デバイスを全て起動/終了」とタイル個別の device-up/device-down)の
   * 直列キュー。ブリッジ供給・simctl・adb が競合しないよう、必ず1件ずつ実行する(実機ログ解析:
   * 並行実行がブリッジ供給の waitUntilReady 失敗・ゾンビブリッジ蓄積を誘発していた)。
   * 状態遷移(queued/running)の純粋ロジックは monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();

  /** ログレーンの純粋な状態(実行を跨いで保持し、パネル再作成時のハイドレーションに使う)。 */
  private readonly laneState = createRunLaneState();
  /** 一度でも実行が始まった(=レーンセクションを表示すべき)かどうか。 */
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;
  /**
   * ftester.profile / ftester.project の変更を監視し、実行プロファイル選択ドロップダウンを
   * 最新化する(モニタープロセス自体は再起動不要。以後のテスト実行・デバッグ実行にのみ効く)。
   */
  private readonly configChangeSubscription: vscode.Disposable;
  /**
   * Projects 配下の各プロジェクトの profiles/runs ディレクトリにある .json ファイルの作成・削除・
   * 変更を監視する。作成・削除は実行プロファイル選択ドロップダウンを最新化する(拡張内の追加/
   * コピー/削除ボタン経由に限らず、エクスプローラーでの手動削除や他ツールでの追加もドロップダウンへ
   * 自動反映されるようにする目的)。変更(Change)は一覧にも選択名にも影響しないため
   * postProfileInfo() は呼ばない代わりに、「プロファイル」タブ下半分の実行プロファイル設定
   * フォームの編集対象と同名であれば runProfileFileChanged を webview へ送り、外部編集(手動編集や
   * 他ツール)をフォームへ自動反映させる(編集中でなければ、の判定は webview 側が行う)。
   */
  private readonly profileFileWatcher: vscode.FileSystemWatcher;
  /**
   * Projects 配下の各プロジェクトの profiles/machines ディレクトリにある .json ファイルの
   * 作成・削除・変更を監視し、「プロファイル」タブのマシンプロファイル一覧を最新化する。
   * profileFileWatcher と違い Change も購読する — マシンプロファイルへのデバイス追記
   * (create-device 成功後や手動編集)は既存ファイルの内容変更として届くため。
   */
  private readonly machineFileWatcher: vscode.FileSystemWatcher;
  /**
   * Projects 配下の各プロジェクトの profiles/apps ディレクトリにある .json ファイルの作成・削除・
   * 変更を監視する(profileFileWatcher と同じ方針)。作成・削除は profileInfo(apps 一覧を含む)を
   * 最新化する postProfileInfo() を呼ぶ。変更(Change)は一覧・選択名には影響しないため、
   * 「プロファイル」タブ中段のアプリプロファイル設定フォームの編集対象と同名であれば
   * appProfileFileChanged を webview へ送り、外部編集を自動反映させる。
   */
  private readonly appsFileWatcher: vscode.FileSystemWatcher;
  /** create-device の多重実行ガード。true の間に来た createDevice リクエストは即座に失敗を返す。 */
  private creatingDevice = false;
  /**
   * 名前入力モーダル(#name-input-overlay)の応答待ち状態。promptName() の呼び出しごとに
   * id を払い出し、webview からの nameInputConfirm/nameInputCancel の id と突き合わせて
   * resolve する(showInputBox 相当の Promise ベースの対話を webview 側モーダルで再現する)。
   */
  private pendingNameInput: { id: number; resolve: (value: string | undefined) => void } | undefined;
  /** promptName() の呼び出しごとに採番する使い捨てID(nameInputConfirm/Cancel との対応付け)。 */
  private nameInputSeq = 0;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
  ) {
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
    this.configChangeSubscription = vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("ftester.profile") || event.affectsConfiguration("ftester.project")) {
        this.postProfileInfo();
        this.restartMonitorIfScopeChanged();
        // ftester.project の変更は対象マシンプロファイル一覧にも影響するため、こちらも最新化する。
        this.postMachineProfileInfo();
      }
    });
    this.profileFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(workspaceRoot, "Projects/*/profiles/runs/*.json"),
    );
    this.profileFileWatcher.onDidCreate(() => this.postProfileInfo());
    this.profileFileWatcher.onDidDelete(() => this.postProfileInfo());
    this.profileFileWatcher.onDidChange((uri) => {
      this.post({ type: "runProfileFileChanged", name: path.basename(uri.fsPath, ".json") });
    });
    this.machineFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(workspaceRoot, "Projects/*/profiles/machines/*.json"),
    );
    this.machineFileWatcher.onDidCreate(() => this.postMachineProfileInfo());
    this.machineFileWatcher.onDidDelete(() => this.postMachineProfileInfo());
    this.machineFileWatcher.onDidChange(() => this.postMachineProfileInfo());
    this.appsFileWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(workspaceRoot, "Projects/*/profiles/apps/*.json"),
    );
    this.appsFileWatcher.onDidCreate(() => this.postProfileInfo());
    this.appsFileWatcher.onDidDelete(() => this.postProfileInfo());
    this.appsFileWatcher.onDidChange((uri) => {
      this.post({ type: "appProfileFileChanged", name: path.basename(uri.fsPath, ".json") });
    });
  }

  /**
   * ftester.profile / ftester.project の変更で、モニターの監視対象デバイス(--profile が絞り込む
   * スコープ)が実際に変わった場合に限り、モニタープロセスを再起動して追随させる。パネル未表示、
   * またはプロジェクトが解決できない(既存のエラーバナー表示に任せる)場合は何もしない。
   * 再起動の前に、切り替え先プロファイルに定義されていない稼働中デバイスの自動シャットダウンを
   * キューに積む(要件2)。
   */
  private restartMonitorIfScopeChanged(): void {
    if (!this.panel) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      return;
    }
    const scope = `${resolution.project} ${config.profile}`;
    if (scope === this.monitorScope) {
      return;
    }
    this.enqueueShutdownOutsideNewScope(resolution.project, config.profile);
    this.restartMonitorProcess();
  }

  /**
   * プロファイル切り替え時、切り替え先プロファイルに定義されていない稼働中デバイスを
   * シャットダウンする(定義されているデバイスは稼働中でもそのまま — 自動起動はしない方針と対)。
   * newProfile が空文字なら「プロファイルなし」= 全デバイスが対象なので何もしない。
   * newProfile が非空で readRunProfileDeviceNames が null を返した場合(プロファイルが読めない)も、
   * devicesToShutdownOnScopeChange(devices, null) は空配列を返す(=絞り込みなし扱い)ため、
   * 結果として自動的にシャットダウンをスキップできる(モニター再起動側の既存のエラー表示で
   * ユーザーが気付ける)。
   */
  private enqueueShutdownOutsideNewScope(project: string, newProfile: string): void {
    const newScopeNames =
      newProfile === "" ? null : readRunProfileDeviceNames(this.workspaceRoot, project, newProfile);
    const targets = devicesToShutdownOnScopeChange(this.lastKnownDevices, newScopeNames);
    if (targets.length === 0) {
      return;
    }
    this.outputChannel.appendLine(
      `[ftester] プロファイル切り替えに伴い監視対象外のデバイスを停止します: ${targets.join(", ")}`,
    );
    for (const name of targets) {
      this.enqueueLifecycleJob({ kind: "device", name, op: "down" });
    }
  }

  /** コマンド `ftester.showDeviceMonitor` のハンドラ。既に開いていれば reveal するだけ。 */
  show(): void {
    if (this.panel) {
      this.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, PANEL_TITLE, vscode.ViewColumn.Beside, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, "media")],
    });
    this.panel = panel;
    panel.webview.html = renderHtml(panel.webview, this.extensionUri);

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.stopMonitorProcess();
      this.stopHostMetricsProcess();
    });

    this.startMonitorProcess();
    // host-metrics の失敗カウンタは新しいパネルごとにリセットする(前回セッションで諦めていても、
    // 開き直したときは素直に起動を試みる。hostMetricsGaveUp 宣言部参照)。
    this.hostMetricsFailureStreak = 0;
    this.hostMetricsGaveUp = false;
    this.startHostMetricsProcess();
    // 初期状態(laneHydrate/profileInfo等)の送信はここでは行わない。html設定直後の
    // postMessage は webview 側スクリプトの message リスナー登録前に届き、VS Code webview の
    // 既知のレースで握りつぶされる(タイル/フレームはモニタープロセスが継続的に流すので
    // 自然回復するが、一度きりの送信であるこれらは落ちたら復旧しない)。webview からの
    // "ready"(初期化完了通知)を受けてから sendInitialState() で送る(ready ハンドシェイク)。
  }

  dispose(): void {
    if (this.pendingNameInput) {
      const resolve = this.pendingNameInput.resolve;
      this.pendingNameInput = undefined;
      resolve(undefined);
    }
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profileFileWatcher.dispose();
    this.machineFileWatcher.dispose();
    this.appsFileWatcher.dispose();
    this.stopMonitorProcess();
    this.stopHostMetricsProcess();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(
    message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage,
  ): void {
    void this.panel?.webview.postMessage(message);
  }

  /** 新しく作成した webview に、既知のレーン状態(直近の実行の途中経過)を一括で流し込む。 */
  private hydrateLaneUi(): void {
    if (this.laneSectionVisible) {
      this.post({ type: "laneSectionVisible", visible: true });
    }
    const snapshot = snapshotRunLaneState(this.laneState);
    if (snapshot.lanes.length > 0 || Object.keys(snapshot.linesByLane).length > 0) {
      this.post({ type: "laneHydrate", snapshot });
    }
  }

  /**
   * 実行プロファイル選択ドロップダウンの内容(一覧+現在値)を webview へ送る。
   * 対象プロジェクトが解決できない場合は一覧を空にする(current はそのまま送る。設定に
   * 手書きされた値の表示自体は webview 側で保つ方針のため)。
   * apps(アプリプロファイル名一覧)は「プロファイル」タブ下半分の実行プロファイル設定フォームの
   * アプリ選択が使う(プロファイル一覧と同じプロジェクトに属するため、ここでまとめて送る)。
   */
  private postProfileInfo(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const profiles =
      resolution.kind === "resolved" ? listRunProfileNames(this.workspaceRoot, resolution.project) : [];
    const apps =
      resolution.kind === "resolved" ? listAppProfileNames(this.workspaceRoot, resolution.project) : [];
    this.post({ type: "profileInfo", profiles, current: config.profile, apps });
  }

  /**
   * 現在使うべきマシンプロファイル名を決める(postMachineProfileInfo・handleProfileAdd 共通)。
   * readLocalMachineName() の値が summaries に存在すればそれを採用し、無ければ summaries が
   * ちょうど1件のときに限りその名前を採用する(あいまいさが無い場合のみ賢く選ぶ、
   * readMachineDeviceNames と同じ方針)。それ以外(0件/複数件で未登録)は null。
   */
  private resolveCurrentMachineName(summaries: readonly MachineProfileSummary[]): string | null {
    const machineName = readLocalMachineName();
    if (machineName !== null && summaries.some((summary) => summary.name === machineName)) {
      return machineName;
    }
    return summaries.length === 1 ? summaries[0]!.name : null;
  }

  /**
   * 「プロファイル」タブのマシンプロファイル一覧(+現在のマシン)を webview へ送る。
   * 対象プロジェクトが解決できない場合は machines を空にしてエラーメッセージを添える
   * (webview 側はこのとき本体の代わりにエラー表示に切り替える)。
   * 現在のマシンの決定は resolveCurrentMachineName を参照。
   */
  private postMachineProfileInfo(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.post({
        type: "machineProfileInfo",
        machines: [],
        current: null,
        error: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      });
      return;
    }
    const summaries = listMachineProfiles(this.workspaceRoot, resolution.project);
    const current = this.resolveCurrentMachineName(summaries);
    const machines = summaries.map((summary) => ({
      name: summary.name,
      devices: summary.devices.map((device) => ({
        name: device.name,
        platform: device.platform,
        detail: machineDeviceDetail(device),
        // 右ペインの編集フォーム用の生フィールド(要件2)。undefined は postMessage の JSON化で
        // 自然に省略される。
        simulator: device.simulator,
        os: device.os,
        udid: device.udid,
        port: device.port,
        avd: device.avd,
      })),
    }));
    this.post({ type: "machineProfileInfo", machines, current, error: null });
  }

  /** RunEventBus からのメッセージ(runHandler.ts の実行と同じインスタンス)をレーン更新に反映する。 */
  private handleBusMessage(message: RunBusMessage): void {
    switch (message.type) {
      case "runStarted":
        this.laneSectionVisible = true;
        this.post({ type: "laneSectionVisible", visible: true });
        break;
      case "event":
        for (const action of reduceLaneEvent(this.laneState, message.event, Date.now())) {
          this.post({ type: "runEvent", action });
        }
        break;
      case "runEnded":
        // runFinished を受信しないまま終了した(異常終了/キャンセル)場合の後始末。
        // 正常終了(runFinished 済み)なら runningWorkers は既に空なので何も起きない。
        for (const action of forceEndRunLaneState(this.laneState)) {
          this.post({ type: "runEvent", action });
        }
        break;
    }
  }

  private handleWebviewMessage(message: unknown): void {
    if (!isMonitorFromWebviewMessage(message)) {
      return;
    }
    switch (message.type) {
      case "ready":
        this.sendInitialState();
        break;
      case "devicesUp":
        this.enqueueLifecycleJob({ kind: "bulk", op: "up" });
        break;
      case "devicesDown":
        this.enqueueLifecycleJob({ kind: "bulk", op: "down" });
        break;
      case "restartMonitor":
        this.restartMonitorProcess();
        // host-metrics の失敗カウンタもリセットして再挑戦する(バイナリ更新後の復帰経路。
        // hostMetricsGaveUp 宣言部参照)。
        this.hostMetricsFailureStreak = 0;
        this.hostMetricsGaveUp = false;
        this.restartHostMetricsProcess();
        break;
      case "deviceOp":
        this.enqueueLifecycleJob({ kind: "device", name: message.name, op: message.op });
        break;
      case "selectProfile":
        this.selectProfile(message.profile);
        break;
      case "profileAdd":
        void this.handleProfileAdd();
        break;
      case "profileCopy":
        void this.handleProfileCopy(message.profile);
        break;
      case "profileDelete":
        void this.handleProfileDelete(message.profile);
        break;
      case "profileRename":
        void this.handleProfileRename(message.profile);
        break;
      case "machineProfileRefresh":
        this.postMachineProfileInfo();
        break;
      case "machineProfileAdd":
        void this.handleMachineProfileAdd();
        break;
      case "machineProfileCopy":
        void this.handleMachineProfileCopy(message.machine);
        break;
      case "machineProfileDelete":
        void this.handleMachineProfileDelete(message.machine);
        break;
      case "machineProfileRename":
        void this.handleMachineProfileRename(message.machine);
        break;
      case "deviceCatalogRequest":
        this.runDeviceCatalog();
        break;
      case "createDevice":
        this.runCreateDevice(message);
        break;
      case "installedDevicesRequest":
        this.runInstalledDevices();
        break;
      case "machineDevicesSync":
        this.handleMachineDevicesSync(message);
        break;
      case "machineDeviceRemove":
        void this.handleMachineDeviceRemove(message.machine, message.names);
        break;
      case "machineDeviceUpdate":
        this.handleMachineDeviceUpdate(message);
        break;
      case "runProfileLoad":
        this.handleRunProfileLoad(message.profile);
        break;
      case "runProfileSave":
        this.handleRunProfileSave(message);
        break;
      case "appProfileAdd":
        void this.handleAppProfileAdd();
        break;
      case "appProfileCopy":
        void this.handleAppProfileCopy(message.profile);
        break;
      case "appProfileDelete":
        void this.handleAppProfileDelete(message.profile);
        break;
      case "appProfileRename":
        void this.handleAppProfileRename(message.profile);
        break;
      case "appProfileLoad":
        this.handleAppProfileLoad(message.profile);
        break;
      case "appProfileSave":
        this.handleAppProfileSave(message);
        break;
      case "nameInputConfirm":
        if (this.pendingNameInput && this.pendingNameInput.id === message.id) {
          const resolve = this.pendingNameInput.resolve;
          this.pendingNameInput = undefined;
          resolve(message.name);
        }
        break;
      case "nameInputCancel":
        if (this.pendingNameInput && this.pendingNameInput.id === message.id) {
          const resolve = this.pendingNameInput.resolve;
          this.pendingNameInput = undefined;
          resolve(undefined);
        }
        break;
    }
  }

  /**
   * 名前入力モーダル(#name-input-overlay)を開き、確定/キャンセルされるまで待つ。
   * showInputBox と同じ契約(キャンセル時 undefined、確定時は入力文字列[未trim])にすることで、
   * 呼び出し側(実行/アプリ/マシンプロファイルの追加・コピー・名前変更、計9箇所)の変更を
   * 最小にする。名前の検証(空/"/""\""/"."始まり/重複)は webview 側で行う(呼び出し側は
   * confirm 後に trim して各自の validateNewXxxName で防御的に再検証する)。
   */
  private promptName(options: {
    readonly title: string;
    readonly value: string;
    readonly noun: string;
    readonly dupLabel: string;
    readonly existing: readonly string[];
    readonly caseInsensitiveDup: boolean;
  }): Promise<string | undefined> {
    // 多重オープンの防御: 既に応答待ちがあれば、上書きする前にキャンセル扱いで解決しておく
    // (通常は9箇所とも同時に開かれることはないが、念のため)。
    if (this.pendingNameInput) {
      const previous = this.pendingNameInput;
      this.pendingNameInput = undefined;
      previous.resolve(undefined);
    }
    this.nameInputSeq += 1;
    const id = this.nameInputSeq;
    return new Promise((resolve) => {
      this.pendingNameInput = { id, resolve };
      this.post({
        type: "nameInputOpen",
        id,
        title: options.title,
        value: options.value,
        noun: options.noun,
        dupLabel: options.dupLabel,
        existing: options.existing,
        caseInsensitiveDup: options.caseInsensitiveDup,
      });
    });
  }

  /**
   * webview のドロップダウン操作を ftester.profile 設定へ反映する
   * (extension.ts の ftester.selectProfile コマンドと同じログ形式で出力チャネルに記録する)。
   * 設定更新に成功すると onDidChangeConfiguration 経由で postProfileInfo() が呼ばれ、
   * webview のドロップダウンが最新化されるので、ここから直接 post する必要はない。
   */
  private selectProfile(profile: string): void {
    const NONE_LABEL = "(プロファイルなし)";
    const displayValue = profile === "" ? NONE_LABEL : profile;
    vscode.workspace
      .getConfiguration("ftester")
      .update("profile", profile, vscode.ConfigurationTarget.Workspace)
      .then(
        () => {
          this.outputChannel.appendLine(`[ftester] 実行プロファイルを「${displayValue}」に設定しました。`);
        },
        (error: unknown) => {
          this.outputChannel.appendLine(
            `[ftester] 実行プロファイルの設定に失敗しました(${displayValue}): ${String(error)}`,
          );
        },
      );
  }

  // ---- 実行プロファイルの追加/コピー/名前変更/削除(プロファイルタブ下半分のアイコンボタン) ------
  // デバイスタブの #profile-select(ftester.profile 設定に連動する選択)自体の挙動は変えない。
  // ここでの追加・コピー・名前変更・削除はいずれも実行プロファイルセクション(編集フォーム)の
  // 編集対象を操作するだけで、ftester.profile 設定(selectProfile)には触れない
  // (名前変更で ftester.profile が対象を指していた場合の追随を除く。handleProfileRename 参照)。
  // 追加・コピーの直後は runProfileSelected で新プロファイルを編集対象として選択する
  // (machineProfileAdd/Copy と同じ方式。以前は生成した JSON をエディタで開いていたが、
  // 下半分のフォームが編集手段になったため廃止した)。

  /** Projects/<project>/profiles/runs ディレクトリの絶対パス。 */
  private runsDir(project: string): string {
    return path.join(this.workspaceRoot, "Projects", project, "profiles", "runs");
  }

  /**
   * 実行プロファイル操作(追加/コピー/名前変更/削除)共通の前提チェック。対象プロジェクトが
   * 解決できない場合は警告して undefined を返す(呼び出し側はここで処理を中断する)。
   */
  private resolveProjectOrWarn(): string | undefined {
    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      void vscode.window.showWarningMessage(
        "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return undefined;
    }
    return resolution.project;
  }

  /** 「+」ボタン: 新しいプロファイル名を入力させ、テンプレート内容で作成して編集対象に選択する。 */
  private async handleProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listRunProfileNames(this.workspaceRoot, project);
    const input = await this.promptName({
      title: "新しい実行プロファイル名",
      value: "",
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewRunProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const runsDir = this.runsDir(project);
    try {
      fs.mkdirSync(runsDir, { recursive: true });
      // 現在のマシンの決定は postMachineProfileInfo の current 決定と同じロジックを使う
      // (あいまいさが無い場合のみ賢く埋める、readMachineDeviceNames と同じ方針)。
      const machine = this.resolveCurrentMachineName(listMachineProfiles(this.workspaceRoot, project)) ?? "";
      const template = buildRunProfileTemplate(
        machine,
        listAppProfileNames(this.workspaceRoot, project),
        readMachineDeviceNames(this.workspaceRoot, project),
      );
      fs.writeFileSync(path.join(runsDir, `${name}.json`), template, "utf8");
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を追加しました。`);
      this.postProfileInfo();
      this.post({ type: "runProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /** 「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製し、複製先を編集対象に選択する。 */
  private async handleProfileCopy(source: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const runsDir = this.runsDir(project);
    const sourcePath = path.join(runsDir, `${source}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${source}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    const existing = listRunProfileNames(this.workspaceRoot, project);
    const input = await this.promptName({
      title: `「${source}」のコピー先の実行プロファイル名`,
      value: `${source}-copy`,
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewRunProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      const content = fs.readFileSync(sourcePath, "utf8");
      fs.mkdirSync(runsDir, { recursive: true });
      fs.writeFileSync(path.join(runsDir, `${name}.json`), content, "utf8");
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${source}」を「${name}」としてコピーしました。`);
      this.postProfileInfo();
      this.post({ type: "runProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /**
   * 「削除」ボタン: モーダル確認で「削除」が選ばれたときのみ削除する。削除したのが現在選択中の
   * プロファイル(ftester.profile)であれば selectProfile("") で「プロファイルなし」に戻す
   * (onDidChangeConfiguration 経由でモニターは全デバイス監視に切り替わる。新スコープが null に
   * なるだけで、devicesToShutdownOnScopeChange(devices, null) は常に空を返すため、この切り替え
   * 自体による自動シャットダウンは発生しない)。
   */
  private async handleProfileDelete(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `実行プロファイル「${name}」を削除しますか?この操作は元に戻せません。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.runsDir(project), `${name}.json`));
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」を削除しました。`);
      if (this.getConfig().profile === name) {
        this.selectProfile("");
      }
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${name}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${name}」の削除に失敗しました。`);
    }
    this.postProfileInfo();
  }

  /**
   * 「✏」ボタン: 新しい名前を入力させ、runs/<name>.json をリネームする(handleMachineProfileRename
   * を手本にした対話形式)。ftester.profile が旧名を指していた場合は selectProfile(新名) で
   * 追随させる(そうしないとアクティブなプロファイルの解決が壊れる。updateLocalMachineName による
   * 登録マシン名の追随と同じ理由)。
   */
  private async handleProfileRename(profile: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const runsDir = this.runsDir(project);
    const oldPath = path.join(runsDir, `${profile}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: 実行プロファイル「${profile}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    // 重複チェックは自分自身(現在の名前)を除いた一覧に対して行う(自分自身への「変更なし」は
    // 別途 newName === profile のチェックで許容するため、existing に含めると常にエラーになってしまう。
    // handleMachineProfileRename と同じ方針)。
    const existing = listRunProfileNames(this.workspaceRoot, project).filter((name) => name !== profile);
    const input = await this.promptName({
      title: `「${profile}」の新しい実行プロファイル名`,
      value: profile,
      noun: "プロファイル名",
      dupLabel: "実行プロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const newName = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewRunProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === profile) {
      return; // 変更なし
    }
    try {
      fs.renameSync(oldPath, path.join(runsDir, `${newName}.json`));
      if (this.getConfig().profile === profile) {
        this.selectProfile(newName);
      }
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」を「${newName}」に変更しました。`);
      this.postProfileInfo();
      this.post({ type: "runProfileSelected", name: newName });
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] 実行プロファイル「${profile}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: 実行プロファイル「${profile}」の名前変更に失敗しました。`);
    }
  }

  // ---- アプリプロファイルの追加/コピー/名前変更/削除(プロファイルタブ中段のアイコンボタン) --------
  // handleProfileAdd/Copy/Delete/Rename(実行プロファイル)の複製。アプリプロファイルは
  // ftester.* のどの設定からも直接参照されないため、selectProfile 相当の追随処理は無い
  // (削除・名前変更どちらも、実行プロファイルの app 参照が古い名前を指したままになりうるが、
  // それは CLI 側の validate-profile が検出する領分としてこの拡張からは追随しない)。

  /** Projects/<project>/profiles/apps ディレクトリの絶対パス。 */
  private appsDir(project: string): string {
    return path.join(this.workspaceRoot, "Projects", project, "profiles", "apps");
  }

  /** 「+」ボタン: 新しいアプリプロファイル名を入力させ、テンプレート内容で作成して編集対象に選択する。 */
  private async handleAppProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listAppProfileNames(this.workspaceRoot, project);
    const input = await this.promptName({
      title: "新しいアプリプロファイル名",
      value: "",
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewAppProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const appsDir = this.appsDir(project);
    try {
      fs.mkdirSync(appsDir, { recursive: true });
      // app はフォームでユーザーが埋める前提のため、テンプレートには appName のみ入れる
      // (buildRunProfileTemplate と違い、埋めるべき候補一覧がここには無いため)。
      const template = { android: {}, common: { appName: name }, ios: {} };
      fs.writeFileSync(path.join(appsDir, `${name}.json`), `${JSON.stringify(template, null, 2)}\n`, "utf8");
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」を追加しました。`);
      this.postProfileInfo();
      this.post({ type: "appProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /** 「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製し、複製先を編集対象に選択する。 */
  private async handleAppProfileCopy(source: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const appsDir = this.appsDir(project);
    const sourcePath = path.join(appsDir, `${source}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: アプリプロファイル「${source}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    const existing = listAppProfileNames(this.workspaceRoot, project);
    const input = await this.promptName({
      title: `「${source}」のコピー先のアプリプロファイル名`,
      value: `${source}-copy`,
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewAppProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      const content = fs.readFileSync(sourcePath, "utf8");
      fs.mkdirSync(appsDir, { recursive: true });
      fs.writeFileSync(path.join(appsDir, `${name}.json`), content, "utf8");
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${source}」を「${name}」としてコピーしました。`);
      this.postProfileInfo();
      this.post({ type: "appProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /**
   * 「削除」ボタン: モーダル確認で「削除」が選ばれたときのみ削除する。実行プロファイルと異なり
   * ftester.* 設定への追従は不要(アプリプロファイルを直接指す設定が無いため)。
   */
  private async handleAppProfileDelete(name: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `アプリプロファイル「${name}」を削除しますか?この操作は元に戻せません。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.appsDir(project), `${name}.json`));
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」を削除しました。`);
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${name}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${name}」の削除に失敗しました。`);
    }
    this.postProfileInfo();
  }

  /**
   * 「✏」ボタン: 新しい名前を入力させ、apps/<name>.json をリネームする(handleProfileRename を
   * 手本にした対話形式)。実行プロファイルの runs/*.json の app フィールドが旧名を指していても、
   * この拡張からは追随しない(壊れた参照は CLI 側の validate-profile が検出する)。
   */
  private async handleAppProfileRename(profile: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const appsDir = this.appsDir(project);
    const oldPath = path.join(appsDir, `${profile}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: アプリプロファイル「${profile}」が見つかりません。`);
      this.postProfileInfo();
      return;
    }
    // 重複チェックは自分自身(現在の名前)を除いた一覧に対して行う(handleProfileRename と同じ方針)。
    const existing = listAppProfileNames(this.workspaceRoot, project).filter((name) => name !== profile);
    const input = await this.promptName({
      title: `「${profile}」の新しいアプリプロファイル名`,
      value: profile,
      noun: "アプリプロファイル名",
      dupLabel: "アプリプロファイル",
      existing,
      caseInsensitiveDup: false,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const newName = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewAppProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === profile) {
      return; // 変更なし
    }
    try {
      fs.renameSync(oldPath, path.join(appsDir, `${newName}.json`));
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」を「${newName}」に変更しました。`);
      this.postProfileInfo();
      this.post({ type: "appProfileSelected", name: newName });
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] アプリプロファイル「${profile}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: アプリプロファイル「${profile}」の名前変更に失敗しました。`);
    }
  }

  /** Projects/<project>/profiles/machines ディレクトリの絶対パス。 */
  private machinesDir(project: string): string {
    return path.join(this.workspaceRoot, "Projects", project, "profiles", "machines");
  }

  // ---- マシンプロファイル自体の追加/削除/名前変更(マシン名横の [+][−][✏] ボタン) -----------------
  // handleProfileAdd/handleProfileDelete(実行プロファイル)と同じ、名前入力はwebview内モーダル
  // (#name-input-overlay)、削除確認はshowWarningMessageを使った対話形式。
  // ただしマシンプロファイルは「今使うマシン」という選択状態を伴うため、
  // 追加/名前変更の直後は machineProfileSelected で webview 側の選択を新プロファイルへ移す
  // (削除後の選択の付け替えは webview 側の既存フォールバックに任せるので送らない)。

  /** マシン名横「+」ボタン: 新しい名前を入力させ、空のスケルトンで machines/<name>.json を作る。 */
  private async handleMachineProfileAdd(): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const existing = listMachineProfiles(this.workspaceRoot, project).map((summary) => summary.name);
    const input = await this.promptName({
      title: "新しいマシンプロファイル名",
      value: "",
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewMachineProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    const machinesDir = this.machinesDir(project);
    try {
      fs.mkdirSync(machinesDir, { recursive: true });
      const skeleton = { android: { devices: [] }, ios: { devices: [] } };
      fs.writeFileSync(path.join(machinesDir, `${name}.json`), `${JSON.stringify(skeleton, null, 2)}\n`, "utf8");
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」を追加しました。`);
      this.postMachineProfileInfo();
      this.post({ type: "machineProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」の追加に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${name}」の追加に失敗しました。`);
    }
  }

  /**
   * マシン名横「コピー」ボタン: コピー元の内容をそのまま新しい名前で複製する
   * (handleProfileCopy(実行プロファイル)と同じフロー。複製後は新プロファイルを選択状態にする)。
   */
  private async handleMachineProfileCopy(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const machinesDir = this.machinesDir(project);
    const sourcePath = path.join(machinesDir, `${machine}.json`);
    if (!fs.existsSync(sourcePath)) {
      void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」が見つかりません。`);
      this.postMachineProfileInfo();
      return;
    }
    const existing = listMachineProfiles(this.workspaceRoot, project).map((summary) => summary.name);
    const input = await this.promptName({
      title: `「${machine}」のコピー先のマシンプロファイル名`,
      value: `${machine}-copy`,
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const name = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewMachineProfileName(name, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    try {
      fs.copyFileSync(sourcePath, path.join(machinesDir, `${name}.json`));
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を「${name}」としてコピーしました。`);
      this.postMachineProfileInfo();
      this.post({ type: "machineProfileSelected", name });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${name}」のコピーに失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${name}」のコピーに失敗しました。`);
    }
  }

  /**
   * マシン名横「✏」ボタン: 新しい名前を入力させ、machines/<machine>.json をリネームする。
   * CLI 側の登録名(`ftester machine set` が書く ~/.config/ftester/config.json の machineName)が
   * 旧名のままだと、リネーム後は一覧に存在しなくなり postMachineProfileInfo の current 決定が
   * 崩れる(登録名を頼りに現在のマシンを選ぶ解決が壊れる)ため、一致していれば追随して書き換える。
   */
  private async handleMachineProfileRename(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const machinesDir = this.machinesDir(project);
    const oldPath = path.join(machinesDir, `${machine}.json`);
    if (!fs.existsSync(oldPath)) {
      void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」が見つかりません。`);
      this.postMachineProfileInfo();
      return;
    }
    // 重複チェックは自分自身(現在の名前)を除いた一覧に対して行う(自分自身への「変更」は
    // 別途 newName === machine のチェックで許容するため、existing に含めると常にエラーになってしまう)。
    const existing = listMachineProfiles(this.workspaceRoot, project)
      .map((summary) => summary.name)
      .filter((name) => name !== machine);
    const input = await this.promptName({
      title: `「${machine}」の新しいマシンプロファイル名`,
      value: machine,
      noun: "マシンプロファイル名",
      dupLabel: "マシンプロファイル",
      existing,
      caseInsensitiveDup: true,
    });
    if (input === undefined) {
      return; // キャンセル
    }
    const newName = input.trim();
    // webview 側検証をすり抜けた場合(レースや古いwebview)の防御的な再検証。
    const nameError = validateNewMachineProfileName(newName, existing);
    if (nameError) {
      void vscode.window.showWarningMessage(`ftester: ${nameError}`);
      return;
    }
    if (newName === machine) {
      return; // 変更なし
    }
    try {
      fs.renameSync(oldPath, path.join(machinesDir, `${newName}.json`));
      if (updateLocalMachineName(machine, newName)) {
        this.outputChannel.appendLine(`[ftester] 登録マシン名(machine set)も「${newName}」に更新しました。`);
      }
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を「${newName}」に変更しました。`);
      this.postMachineProfileInfo();
      this.post({ type: "machineProfileSelected", name: newName });
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」の名前変更に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」の名前変更に失敗しました。`);
    }
  }

  /**
   * マシン名横「−」ボタン: モーダル確認の上、machines/<machine>.json を削除する
   * (シミュレータ/AVD 本体はここでは一切操作しない。handleProfileDelete と同じ方針)。
   * 選択の付け替えは webview 側の既存フォールバック(machineProfileInfo 受信時の current→先頭)に
   * 任せるので、ここから machineProfileSelected は送らない。
   */
  private async handleMachineProfileDelete(machine: string): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `マシンプロファイル「${machine}」を削除しますか?この操作は元に戻せません(プロファイルファイルのみ削除され、シミュレータ/AVD 本体は削除されません)。`,
      { modal: true },
      "削除",
    );
    if (choice !== "削除") {
      return;
    }
    try {
      fs.unlinkSync(path.join(this.machinesDir(project), `${machine}.json`));
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」を削除しました。`);
      this.postMachineProfileInfo();
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] マシンプロファイル「${machine}」の削除に失敗しました: ${String(error)}`);
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」の削除に失敗しました。`);
    }
  }

  /**
   * プロファイルタブのデバイス行右クリックメニュー「除去」/「選択した<N>台を除去」:
   * machines/<machine>.json から names に一致するデバイスをプロファイル上だけ取り除く
   * (シミュレータ/AVD本体はここでは一切操作しない。handleProfileDelete と同じくモーダル確認を
   * 経てから実行する)。ユーザー可視文言はこの操作に限り「削除」ではなく「除去」を使う
   * (2026-07-11 ユーザー指示: プロファイルから外すだけなのに、仮想マシン本体を消す「削除」と
   * 紛らわしいため。本体を本当に消す操作・プロファイル自体の削除は従来どおり「削除」)。
   * 複数選択(要件5)に対応するため names は配列(単一除去も要素数1の配列)。
   * removeDeviceFromMachineProfile を名前ごとに順次適用する(1回のファイル読み書きで済ませる —
   * 各適用結果の object を次の入力にすることで、まとめて1回の書き戻しにできる)。1件も除去
   * できなければ(全名前が見つからなければ)警告して書き戻さない。
   */
  private async handleMachineDeviceRemove(machine: string, names: readonly string[]): Promise<void> {
    const project = this.resolveProjectOrWarn();
    if (!project) {
      return;
    }
    const confirmMessage =
      names.length === 1
        ? `マシンプロファイル「${machine}」からデバイス「${names[0]}」を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。`
        : `マシンプロファイル「${machine}」から${names.length}台のデバイス(${summarizeDeviceNames(names)})を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。`;
    const choice = await vscode.window.showWarningMessage(confirmMessage, { modal: true }, "除去");
    if (choice !== "除去") {
      return;
    }
    const machinePath = path.join(this.machinesDir(project), `${machine}.json`);
    try {
      let parsed: unknown;
      try {
        parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
      } catch (error) {
        this.outputChannel.appendLine(
          `[ftester] マシンプロファイル「${machine}」の読み込みに失敗しました: ${String(error)}`,
        );
        void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」を読み込めませんでした。`);
        return;
      }
      let current: unknown = parsed;
      let removedCount = 0;
      for (const name of names) {
        const result = removeDeviceFromMachineProfile(current, name);
        if (!result) {
          this.outputChannel.appendLine(
            `[ftester] マシンプロファイル「${machine}」の形式が不正なため、デバイスの除去を中断しました。`,
          );
          void vscode.window.showWarningMessage(`ftester: マシンプロファイル「${machine}」を読み込めませんでした。`);
          return;
        }
        current = result.object;
        if (result.removed) {
          removedCount += 1;
        }
      }
      if (removedCount === 0) {
        this.outputChannel.appendLine(
          `[ftester] マシンプロファイル「${machine}」に指定のデバイスが見つからず、除去できませんでした。`,
        );
        void vscode.window.showWarningMessage(
          `ftester: マシンプロファイル「${machine}」に指定のデバイスが見つかりませんでした。`,
        );
        return;
      }
      fs.writeFileSync(machinePath, `${JSON.stringify(current, null, 2)}\n`, "utf8");
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」から${removedCount}台のデバイスを除去しました(${names.join("、")})。`,
      );
      // FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
      // runCreateDevice と同じく反映を待たせないようここでも明示的に呼ぶ(冪等)。
      this.postMachineProfileInfo();
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${machine}」からのデバイス除去に失敗しました: ${String(error)}`,
      );
      void vscode.window.showErrorMessage(`ftester: マシンプロファイル「${machine}」からのデバイス除去に失敗しました。`);
    }
  }

  /**
   * プロファイルタブ右ペインの編集フォーム「確定」: machines/<machine>.json の対象デバイスを
   * 更新する。結果はモーダル確認なしに machineDeviceUpdateResult で即座に webview へ返す
   * (フォーム自体がクライアント側検証を経ているため、handleMachineDeviceRemove と違い確認
   * ダイアログは不要)。対象プロジェクトが解決できない場合も(resolveProjectOrWarn の
   * vscode.window 警告ではなく)結果メッセージのエラーとしてフォームに表示させたいので、
   * ここでは resolveProjectName を直接呼ぶ。
   */
  private handleMachineDeviceUpdate(message: MachineDeviceUpdateMessage): void {
    const sendResult = (ok: boolean, name: string, error: string | null) => {
      this.post({ type: "machineDeviceUpdateResult", ok, name, error });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        message.originalName,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return;
    }

    const machinePath = path.join(this.machinesDir(resolution.project), `${message.machine}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」の読み込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, message.originalName, `マシンプロファイル「${message.machine}」を読み込めませんでした。`);
      return;
    }

    const result = updateDeviceInMachineProfile(parsed, message.platform, message.originalName, message.fields);
    if (!result.ok) {
      sendResult(false, message.originalName, result.error);
      return;
    }

    try {
      fs.writeFileSync(machinePath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」のデバイス「${message.originalName}」の更新に失敗しました: ${String(error)}`,
      );
      sendResult(false, message.originalName, `マシンプロファイル「${message.machine}」への書き込みに失敗しました。`);
      return;
    }

    this.outputChannel.appendLine(
      `[ftester] マシンプロファイル「${message.machine}」のデバイス「${message.originalName}」を更新しました。`,
    );
    sendResult(true, result.name, null);
    // FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
    // handleMachineDeviceRemove と同じく反映を待たせないようここでも明示的に呼ぶ(冪等)。
    this.postMachineProfileInfo();
  }

  /**
   * 「+既存から選択」モーダル(#device-pick-overlay)の OK: machines/<machine>.json へ、
   * チェックの差分(新たにチェックした未登録デバイスの追加/外した登録済みデバイスの登録解除)を
   * まとめて適用する。handleMachineDeviceUpdate と同じく、モーダル確認なしに
   * machineDevicesSyncResult で即座に webview へ返す(モーダル自体がチェックボックス操作という
   * 明示操作を経ているため)。対象プロジェクトが解決できない場合も結果メッセージのエラーとして
   * 返す(handleMachineDeviceUpdate と同じ理由で resolveProjectName を直接呼ぶ)。
   */
  private handleMachineDevicesSync(message: MachineDevicesSyncMessage): void {
    const sendResult = (ok: boolean, added: number, removed: number, error: string | null) => {
      this.post({ type: "machineDevicesSyncResult", ok, added, removed, error });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, 0, 0, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const machinePath = path.join(this.machinesDir(resolution.project), `${message.machine}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(machinePath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」の読み込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, 0, 0, `マシンプロファイル「${message.machine}」を読み込めませんでした。`);
      return;
    }

    const result = syncDevicesInMachineProfile(parsed, message.add, message.remove);
    if (!result.ok) {
      sendResult(false, 0, 0, result.error);
      return;
    }

    try {
      fs.writeFileSync(machinePath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] マシンプロファイル「${message.machine}」へのデバイス同期の書き込みに失敗しました: ${String(error)}`,
      );
      sendResult(false, 0, 0, `マシンプロファイル「${message.machine}」への書き込みに失敗しました。`);
      return;
    }

    this.outputChannel.appendLine(
      `[ftester] マシンプロファイル「${message.machine}」に追加${result.added.length}台・登録解除${result.removed}台を適用しました` +
        `(追加: ${result.added.length > 0 ? result.added.join("、") : "なし"}、` +
        `登録解除: ${message.remove.length > 0 ? message.remove.join("、") : "なし"})。`,
    );
    sendResult(true, result.added.length, result.removed, null);
    // FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
    // handleMachineDeviceUpdate と同じく反映を待たせないようここでも明示的に呼ぶ(冪等)。
    this.postMachineProfileInfo();
  }

  // ---- プロファイルタブ下半分: 実行プロファイルの設定フォーム(runProfileLoad/runProfileSave) ----
  // フォーム自体の検証は webview 側(クライアント検証)で完結させているが、updateRunProfileInObject
  // 側の防御的な検証(defaultTimeout の型)にも引っかかりうるため、結果は machineDeviceUpdate と同じく
  // モーダル確認なしに即座に webview へ返す。

  /**
   * 選択変更・初回表示時のロード要求への応答。対象プロジェクトが解決できない/ファイルが
   * 読めない/JSON として解析できない/トップレベルが非オブジェクトのいずれも ok:false + fields:null
   * で返す(フォーム側はこれを「表示できない」として扱う)。
   */
  private handleRunProfileLoad(profile: string): void {
    const sendResult = (ok: boolean, error: string | null, fields: RunProfileFormFields | null) => {
      this.post({ type: "runProfileData", profile, ok, error, fields });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        null,
      );
      return;
    }

    const runPath = path.join(this.runsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(runPath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」を読み込めませんでした。`, null);
      return;
    }

    const fields = parseRunProfileForForm(parsed);
    if (!fields) {
      sendResult(false, `実行プロファイル「${profile}」の形式が不正です。`, null);
      return;
    }
    sendResult(true, null, fields);
  }

  /**
   * 「確定」への応答。書き込み成功後、続けて handleRunProfileLoad を呼び直し、最新の fields を
   * 再送する(保存直後にフォームを最新化させるため。machineDeviceUpdate 系が
   * postMachineProfileInfo() を明示的に呼び直しているのと同じ理由)。
   */
  private handleRunProfileSave(message: RunProfileSaveMessage): void {
    const { profile, fields } = message;
    const sendResult = (ok: boolean, error: string | null) => {
      this.post({ type: "runProfileSaveResult", profile, ok, error });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const runPath = path.join(this.runsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(runPath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」を読み込めませんでした。`);
      return;
    }

    const result = updateRunProfileInObject(parsed, fields);
    if (!result.ok) {
      sendResult(false, result.error);
      return;
    }

    try {
      fs.writeFileSync(runPath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」の書き込みに失敗しました: ${String(error)}`);
      sendResult(false, `実行プロファイル「${profile}」への書き込みに失敗しました。`);
      return;
    }

    this.outputChannel.appendLine(`[ftester] 実行プロファイル「${profile}」を更新しました。`);
    sendResult(true, null);
    this.handleRunProfileLoad(profile);
  }

  // ---- プロファイルタブ中段: アプリプロファイルの設定フォーム(appProfileLoad/appProfileSave) ----
  // handleRunProfileLoad/handleRunProfileSave の複製。フォーム自体の必須検証は無い(全フィールド
  // 省略可)ため、updateAppProfileInObject が ok:false を返すことは実質無い想定だが、念のため
  // 同じ形で結果を返す。

  /**
   * 選択変更・初回表示時のロード要求への応答。対象プロジェクトが解決できない/ファイルが
   * 読めない/JSON として解析できない/トップレベルが非オブジェクトのいずれも ok:false + fields:null
   * で返す(handleRunProfileLoad と同じ方針)。
   */
  private handleAppProfileLoad(profile: string): void {
    const sendResult = (ok: boolean, error: string | null, fields: AppProfileFormFields | null) => {
      this.post({ type: "appProfileData", profile, ok, error, fields });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(
        false,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        null,
      );
      return;
    }

    const appPath = path.join(this.appsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(appPath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」を読み込めませんでした。`, null);
      return;
    }

    const fields = parseAppProfileForForm(parsed);
    if (!fields) {
      sendResult(false, `アプリプロファイル「${profile}」の形式が不正です。`, null);
      return;
    }
    sendResult(true, null, fields);
  }

  /**
   * 「確定」への応答。書き込み成功後、続けて handleAppProfileLoad を呼び直し、最新の fields を
   * 再送する(handleRunProfileSave と同じ理由)。
   */
  private handleAppProfileSave(message: AppProfileSaveMessage): void {
    const { profile, fields } = message;
    const sendResult = (ok: boolean, error: string | null) => {
      this.post({ type: "appProfileSaveResult", profile, ok, error });
    };

    const resolution = resolveProjectName(this.workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      sendResult(false, "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。");
      return;
    }

    const appPath = path.join(this.appsDir(resolution.project), `${profile}.json`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(appPath, "utf8"));
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の読み込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」を読み込めませんでした。`);
      return;
    }

    const result = updateAppProfileInObject(parsed, fields);
    if (!result.ok) {
      sendResult(false, result.error);
      return;
    }

    try {
      fs.writeFileSync(appPath, `${JSON.stringify(result.object, null, 2)}\n`, "utf8");
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」の書き込みに失敗しました: ${String(error)}`);
      sendResult(false, `アプリプロファイル「${profile}」への書き込みに失敗しました。`);
      return;
    }

    this.outputChannel.appendLine(`[ftester] アプリプロファイル「${profile}」を更新しました。`);
    sendResult(true, null);
    this.handleAppProfileLoad(profile);
  }

  private startMonitorProcess(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.monitorScope = undefined;
      this.post({
        type: "processDown",
        message:
          "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      });
      return;
    }

    const interval = Math.max(0.5, config.monitorInterval);
    const args = [
      "api",
      "monitor",
      "--project",
      resolution.project,
      "--interval",
      String(interval),
      "--max-width",
      String(config.monitorMaxWidth),
    ];
    if (config.profile) {
      // 実行プロファイルが参照するデバイスのみに監視対象を絞り込む(空なら全デバイス。CLI 側の既定)。
      args.push("--profile", config.profile);
    }
    // 実際に使った監視スコープを記録する(restartMonitorIfScopeChanged() が変化検知に使う)。
    this.monitorScope = `${resolution.project} ${config.profile}`;

    let proc: MonitorProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] monitor プロセスの起動に失敗しました: ${String(error)}`);
      this.post({
        type: "processDown",
        message: `モニタープロセスの起動に失敗しました: ${String(error)}`,
      });
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する。
    // 相手が先に死んだ後の書き込み(end等)で EPIPE が飛んでも拡張を落とさない。
    proc.stdin.on("error", () => undefined);

    this.stoppingMonitor = false;
    this.monitorProcess = proc;

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          this.outputChannel.appendLine(
            `[monitor] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "monitorDevices") {
          // モニター再起動(プロファイル切り替え含む)を跨いで保持する(lastKnownDevices 宣言部参照)。
          this.lastKnownDevices = value.devices;
        }
        this.post(toWebviewMessage(value));
      },
      (line) => this.outputChannel.appendLine(`[monitor stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[monitor stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[monitor stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(`[ftester] monitor プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", (exitCode, signal) => {
      stdoutParser.end();
      stderrParser.end();
      if (this.monitorProcess === proc) {
        this.monitorProcess = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する。
      // stdin EOF 経由で終了した場合は signal が null になるため、signal では判定できない。
      const selfInitiated = this.stoppingMonitor;
      this.stoppingMonitor = false;
      if (!selfInitiated) {
        // exit 0 の予期しない終了(過去例: stdin の扱いの不備)も無言にせず必ず通知する。
        const hint =
          exitCode === 0
            ? "予期せず終了しました。「モニター再起動」で再開できます。"
            : "マシンプロファイル未設定の可能性があります。" +
              "「ftester machine set」の実行、または Projects/<project>/profiles/machines/ の内容を確認してください。";
        this.post({
          type: "processDown",
          message: `モニタープロセスが終了しました(exit code: ${String(exitCode)}, signal: ${String(signal)})。${hint}`,
        });
      }
    });
  }

  /** 実行中の monitor プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める。無ければ何もしない。 */
  private stopMonitorProcess(): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingMonitor = true;
    // 行儀よく stdin EOF(=終了指示)を送ってから SIGTERM も送る(どちらでもクリーンに終了する)。
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * monitor プロセスを止めてから起動し直す(「モニター再起動」ボタン、および
   * restartMonitorIfScopeChanged() による監視対象追随の両方から呼ばれる)。
   * 多重起動ガード: restartPending が true の間は追加の呼び出しを無視する(連続したプロファイル
   * 変更やボタン連打で stopMonitorProcess()/startMonitorProcess() が重なり、monitor プロセスが
   * 二重起動するのを防ぐ)。ガードで潰された再起動要求があっても実害はない — 実際に走る
   * startMonitorProcess() は呼び出し時点の getConfig() を読むので、最終的に反映されるのは
   * 常に最新の設定であるため。
   */
  private restartMonitorProcess(): void {
    if (this.restartPending) {
      return;
    }
    this.restartPending = true;
    const proc = this.monitorProcess;
    this.stopMonitorProcess();
    if (!proc) {
      this.restartPending = false;
      this.startMonitorProcess();
      return;
    }
    proc.once("close", () => {
      this.restartPending = false;
      this.startMonitorProcess();
    });
  }

  /**
   * host-metrics プロセス(`ftester api host-metrics --interval 1`)を spawn する。monitor プロセスと
   * 同じく stdin をパイプで保持したまま何も書かない(EOF が終了指示)。--project/--profile は
   * 付けない — ホストMac自体の値であり監視対象デバイスに依存しないため(プロファイル/プロジェクト
   * 切り替えでの再起動は不要。restartMonitorIfScopeChanged() からは呼ばない)。
   */
  private startHostMetricsProcess(): void {
    // 予約済みの自動再起動があれば無効化する。「プロセス終了→close 未配送」の隙間で
    // restartHostMetricsProcess()(モニター再起動ボタン)が走ると、close ハンドラが積んだ
    // 5秒後の自動再起動と本起動の両方が生きて host-metrics が二重起動し得るため、
    // どの経路から起動する場合も先にタイマーを消す。
    if (this.hostMetricsRestartTimer) {
      clearTimeout(this.hostMetricsRestartTimer);
      this.hostMetricsRestartTimer = undefined;
    }
    const config = this.getConfig();
    let proc: MonitorProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "host-metrics", "--interval", "1"], {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[host-metrics] プロセスの起動に失敗しました: ${String(error)}`);
      return;
    }

    // stdin は EOF が終了指示なので、こちらからは何も書かず開いたまま保持する(monitor と同じ)。
    proc.stdin.on("error", () => undefined);

    this.stoppingHostMetrics = false;
    this.hostMetricsProcess = proc;
    this.hostMetricsStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isHostMetricsEvent(value)) {
          this.outputChannel.appendLine(`[host-metrics] 未知の形式の行を無視しました: ${JSON.stringify(value)}`);
          return;
        }
        this.post({
          type: "hostMetrics",
          cpu: value.cpu,
          gpu: value.gpu,
          ane: value.ane,
          aneWatts: value.aneWatts,
          memUsedBytes: value.memUsedBytes,
          memTotalBytes: value.memTotalBytes,
        });
      },
      (line) => this.outputChannel.appendLine(`[host-metrics stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[host-metrics stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[host-metrics stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(`[host-metrics] プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.hostMetricsProcess === proc) {
        this.hostMetricsProcess = undefined;
      }
      // 意図した停止(dispose/再起動)かどうかはフラグだけで判定する(monitor と同じ理由)。
      const selfInitiated = this.stoppingHostMetrics;
      this.stoppingHostMetrics = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleHostMetricsRestart();
    });
  }

  /**
   * host-metrics プロセスの予期しない終了を受けて、再起動するか諦めるかを決める(startHostMetricsProcess
   * の close ハンドラから呼ばれる)。起動後10秒未満での異常終了が3回連続したら諦めて outputChannel に
   * 1回だけログし、以後 hostMetricsGaveUp が true の間は再起動をスケジュールしない(旧バイナリに
   * host-metrics サブコマンドが無い環境で無限に再起動ループしないための安全弁)。10秒以上動いてからの
   * 終了は正常運転とみなして連続回数をリセットする。
   */
  private scheduleHostMetricsRestart(): void {
    const elapsedMs = Date.now() - (this.hostMetricsStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.hostMetricsFailureStreak += 1;
    } else {
      this.hostMetricsFailureStreak = 0;
    }
    if (this.hostMetricsFailureStreak >= 3) {
      if (!this.hostMetricsGaveUp) {
        this.hostMetricsGaveUp = true;
        this.outputChannel.appendLine(
          "[host-metrics] 起動直後の異常終了が続いたため自動再起動を停止しました。" +
            "バイナリが `api host-metrics` に対応しているか確認してください" +
            "(対応後は「モニター再起動」ボタンで復帰できます)。",
        );
      }
      return;
    }
    this.hostMetricsRestartTimer = setTimeout(() => {
      this.hostMetricsRestartTimer = undefined;
      // 5秒待つ間にパネルが閉じられていたら何もしない。
      if (this.panel) {
        this.startHostMetricsProcess();
      }
    }, 5000);
  }

  /** 実行中の host-metrics プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める(stopMonitorProcess と同じ方針)。 */
  private stopHostMetricsProcess(): void {
    if (this.hostMetricsRestartTimer) {
      clearTimeout(this.hostMetricsRestartTimer);
      this.hostMetricsRestartTimer = undefined;
    }
    const proc = this.hostMetricsProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingHostMetrics = true;
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * host-metrics プロセスを止めてから起動し直す(「モニター再起動」ボタンから呼ばれる)。
   * 多重起動ガードは restartMonitorProcess と同じ理由(連打で二重起動しないようにする)。
   */
  private restartHostMetricsProcess(): void {
    if (this.hostMetricsRestartPending) {
      return;
    }
    this.hostMetricsRestartPending = true;
    const proc = this.hostMetricsProcess;
    this.stopHostMetricsProcess();
    if (!proc) {
      this.hostMetricsRestartPending = false;
      this.startHostMetricsProcess();
      return;
    }
    proc.once("close", () => {
      this.hostMetricsRestartPending = false;
      this.startHostMetricsProcess();
    });
  }

  /**
   * デバイスライフサイクル操作(devicesUp/devicesDown/deviceOp)をキューに積む。
   * キューが空(何も実行中でない)ならそのまま実行を開始し、そうでなければ先に積まれている
   * ジョブの完了後に順番に実行される。同じデバイスへの deviceOp が既にキュー内(実行中または
   * 待機中)にある場合は連打とみなして無視する(グローバルボタン側は呼び出し元
   * (handleWebviewMessage 経由)では素通しだが、`isDeviceLifecycleQueueBusy` を見て webview 側の
   * ボタンが disabled になっているため、通常はここに届く前に抑止される)。
   */
  private enqueueLifecycleJob(job: DeviceLifecycleJob): void {
    if (job.kind === "device" && hasDeviceLifecycleJobFor(this.lifecycleQueue, job.name)) {
      return;
    }
    const wasBusy = isDeviceLifecycleQueueBusy(this.lifecycleQueue);
    this.lifecycleQueue = enqueueDeviceLifecycleJob(this.lifecycleQueue, job);
    if (!wasBusy) {
      // キューが空だったので、このジョブがそのまま先頭になり即実行される。
      this.post({ type: "bootBusy", busy: true });
      this.runLifecycleQueueHead();
    } else if (job.kind === "device") {
      // 何か実行中/待機中なので、このジョブは順番待ち(「待機中...」バッジ)になる。
      this.postDeviceLifecycleStatus(job.name);
    }
  }

  /** 指定デバイスの現在のキュー状態(実行中/待機中/なし)を deviceOpBusy として webview に送る。 */
  private postDeviceLifecycleStatus(name: string): void {
    const status = deviceLifecycleStatusFor(this.lifecycleQueue, name);
    this.post({ type: "deviceOpBusy", name, op: status?.op ?? null, status: status?.status ?? null });
  }

  /**
   * webview からの "ready"(初期化完了通知)を受けて、初期状態をまとめて送る(ready ハンドシェイク)。
   * ready は webview 再読込(タブのエディタグループ移動等)のたびに再送されうるので、ここで行う
   * 各処理が冪等であることが前提になる(hydrateLaneUi はスナップショットの一括送信、
   * profileInfo・以下のライフサイクル状態の再送はいずれも webview 側で上書き描画するだけなので
   * 何度呼んでも問題ない)。
   */
  private sendInitialState(): void {
    this.hydrateLaneUi();
    this.postProfileInfo();
    this.postMachineProfileInfo();
    // デバイスライフサイクルキューの状態も再送する(webview 再読込がジョブ実行中に起きた場合に、
    // ボタンの無効状態・タイルのバッジを復元するため)。
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.post({ type: "bootBusy", busy: true });
    }
    for (const job of this.lifecycleQueue.jobs) {
      if (job.kind === "device") {
        this.postDeviceLifecycleStatus(job.name);
      }
    }
  }

  /** キュー先頭のジョブを実行する(devices up/down の一括実行、または device-up/down の個別実行)。 */
  private runLifecycleQueueHead(): void {
    const job = deviceLifecycleQueueHead(this.lifecycleQueue);
    if (!job) {
      return;
    }
    // down 系ジョブ(bulk down / device-down)は実行直前にモニターへ pause を送り、片付け中の
    // デバイスへポーリングがスクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系は起動進行を
    // タイルで見たいので pause しない。
    if (deviceLifecycleJobNeedsMonitorPause(job)) {
      this.writeMonitorControl("pause");
    }
    if (job.kind === "bulk") {
      this.executeBulkJob(job.op);
    } else {
      // 待機中だったジョブがここで先頭に回ってきた場合も含め、「実行中」バッジに更新する。
      this.postDeviceLifecycleStatus(job.name);
      this.executeDeviceOpJob(job.name, job.op);
    }
  }

  /**
   * 先頭ジョブの完了後始末。キューから取り除き、残りがあれば続けて次を実行し、
   * 空になったらグローバルボタンの busy 状態を解除する。
   */
  private finishLifecycleQueueHead(): void {
    const finished = deviceLifecycleQueueHead(this.lifecycleQueue);
    // pause した down 系ジョブは、成功・失敗を問わずここ(finally 相当)でモニターを resume する。
    if (finished && deviceLifecycleJobNeedsMonitorPause(finished)) {
      this.writeMonitorControl("resume");
    }
    this.lifecycleQueue = dequeueDeviceLifecycleJob(this.lifecycleQueue);
    if (finished?.kind === "device") {
      this.post({ type: "deviceOpBusy", name: finished.name, op: null, status: null });
    }
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.runLifecycleQueueHead();
    } else {
      this.post({ type: "bootBusy", busy: false });
    }
  }

  /**
   * モニタープロセスの stdin に pause/resume の制御コマンドを書き込む(NDJSON 1行)。
   * モニターが未起動・終了済みのときは黙ってスキップする(エラーにしない)。書き込み自体が
   * 失敗した場合も握りつぶし、呼び出し元のジョブ実行は継続させる(stdin の "error" ハンドラは
   * startMonitorProcess() 側で既に no-op 登録済み)。
   */
  private writeMonitorControl(cmd: MonitorControlCommand): void {
    const proc = this.monitorProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    try {
      proc.stdin.write(monitorControlLine(cmd));
    } catch {
      // 書き込み失敗は無視する(ジョブ自体は続行する)。
    }
  }

  /**
   * `ftester devices up`/`devices down` を短命プロセスとして実行する(bulk ジョブの実処理)。
   * 選択中の実行プロファイル(ftester.profile)が非空なら --profile を付与し、対象を
   * そのプロファイルが参照するデバイスのみに限定する(要件1。空ならマシンプロファイルの全デバイス。
   * down は元々引数なしの全体停止だったが、--profile 対応により --project/--profile を渡せるようにした)。
   */
  private executeBulkJob(kind: "up" | "down"): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const args: string[] = ["devices", kind];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }
    if (config.profile) {
      args.push("--profile", config.profile);
    }

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // finishLifecycleQueueHead() はキュー先頭を1回だけ取り除く前提なので、二重呼び出しを防ぐ。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleQueueHead();
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] devices ${kind} の起動に失敗しました: ${String(error)}`);
      finishOnce();
      return;
    }

    const appendLines = (stream: "stdout" | "stderr", chunk: Buffer): void => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          this.outputChannel.appendLine(`[devices ${kind} ${stream}] ${line}`);
        }
      }
    };
    proc.stdout.on("data", (chunk: Buffer) => appendLines("stdout", chunk));
    proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} の実行でエラーが発生しました: ${error.message}`,
      );
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} が終了しました(exit code: ${String(exitCode)})`,
      );
      finishOnce();
    });
  }

  /**
   * タイル右クリックメニューの起動/停止項目から、デバイス1台だけを
   * `ftester api device-up`/`device-down` で起動/停止する(device ジョブの実処理)。
   * finished イベントが ok:false のとき、およびプロセスが異常終了したとき(finished を出せずに
   * 落ちた場合を含む)は、webview のエラーバナーに加えて出力チャネルにも必ずログを残す
   * (バナーはパネルを閉じると消えるため、事後診断できるよう出力チャネル側にも記録する)。
   */
  private executeDeviceOpJob(name: string, op: DeviceOpKind): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const args: string[] = ["api", op === "up" ? "device-up" : "device-down", "--name", name];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }

    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.outputChannel.appendLine(`[ftester] device-${op}(${name})が失敗しました: ${message}`);
    };

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // finishLifecycleQueueHead() はキュー先頭を1回だけ取り除く前提なので、二重呼び出しを防ぐ。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleQueueHead();
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      logFailure(String(error));
      this.post({ type: "deviceOpFailed", name, message: String(error) });
      finishOnce();
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDeviceOpEvent(value)) {
          this.outputChannel.appendLine(
            `[device-${op} ${name}] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "log") {
          this.outputChannel.appendLine(`[device-${op} ${name}] ${value.message}`);
        } else if (!value.ok) {
          const message = value.error ?? `device-${op} に失敗しました。`;
          logFailure(message);
          this.post({ type: "deviceOpFailed", name, message });
        }
      },
      (line) => this.outputChannel.appendLine(`[device-${op} ${name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[device-${op} ${name} stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[device-${op} ${name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      logFailure(error.message);
      this.post({ type: "deviceOpFailed", name, message: error.message });
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.outputChannel.appendLine(
        `[ftester] device-${op}(${name})が終了しました(exit code: ${String(exitCode)})`,
      );
      // finished(ok:false)を経由せずに落ちたケース(クラッシュ・kill 等)を捕捉する。
      // finished 経由で既にログ済みの場合は二重に出さない。
      if (!failureLogged && exitCode !== 0) {
        logFailure(`プロセスが exit code ${String(exitCode)} で終了しました`);
      }
      finishOnce();
    });
  }

  // ---- マシンプロファイル(プロファイルタブ): デバイスカタログ取得・デバイス追加 -----------------
  // いずれもデバイスライフサイクルの直列キュー(lifecycleQueue)には載せない —
  // device-catalog は単なる参照系の単発コマンド、create-device もモーダル側の1件実行ガード
  // (creatingDevice)で十分であり、simctl/adb 起動系のキューと競合する処理ではないため。

  /**
   * `ftester api device-catalog` を短命プロセスとして実行し、結果を webview へ返す。
   * 多重リクエストはボタン側(モーダルは開いた直後に1回だけ送る)で抑止する前提のため、
   * ここでは単純に都度実行する。stdout を全量蓄積し、close 時にまとめて JSON.parse する
   * (単発 JSON 1行の出力なので NDJSON パーサは不要)。
   */
  private runDeviceCatalog(): void {
    const config = this.getConfig();

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "device-catalog"], {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = `device-catalog の起動に失敗しました: ${String(error)}`;
      this.outputChannel.appendLine(`[ftester] ${message}`);
      this.post({ type: "deviceCatalog", ok: false, catalog: null, error: message });
      return;
    }

    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // 二重に post しないようにガードする(executeDeviceOpJob の finishOnce パターンと同じ)。
    let responded = false;
    const respond = (message: MonitorToWebviewMessage): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.post(message);
    };
    const flushStderr = (): void => {
      const trimmed = stderr.trim();
      if (trimmed.length > 0) {
        this.outputChannel.appendLine(`[device-catalog stderr] ${trimmed}`);
      }
    };

    proc.on("error", (error) => {
      const message = `device-catalog の実行でエラーが発生しました: ${error.message}`;
      this.outputChannel.appendLine(`[ftester] ${message}`);
      flushStderr();
      respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const message = `device-catalog が失敗しました(exit code: ${String(exitCode)})`;
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = `device-catalog の出力を解析できませんでした: ${String(error)}`;
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      if (!isDeviceCatalogJson(parsed)) {
        const message = "device-catalog の出力形式が不正です。";
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      respond({ type: "deviceCatalog", ok: true, catalog: parsed, error: null });
    });
  }

  /**
   * `ftester api installed-devices` を短命プロセスとして実行し、結果を webview へ返す
   * (「+既存から選択」モーダルが開いた直後の installedDevicesRequest への応答。runDeviceCatalog と
   * 全く同じ短命 spawn パターン — 単発 JSON 1行の出力を全量蓄積して close 時にまとめて
   * JSON.parse する)。
   */
  private runInstalledDevices(): void {
    const config = this.getConfig();

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "installed-devices"], {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = `installed-devices の起動に失敗しました: ${String(error)}`;
      this.outputChannel.appendLine(`[ftester] ${message}`);
      this.post({ type: "installedDevices", ok: false, data: null, error: message });
      return;
    }

    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    let responded = false;
    const respond = (message: MonitorToWebviewMessage): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.post(message);
    };
    const flushStderr = (): void => {
      const trimmed = stderr.trim();
      if (trimmed.length > 0) {
        this.outputChannel.appendLine(`[installed-devices stderr] ${trimmed}`);
      }
    };

    proc.on("error", (error) => {
      const message = `installed-devices の実行でエラーが発生しました: ${error.message}`;
      this.outputChannel.appendLine(`[ftester] ${message}`);
      flushStderr();
      respond({ type: "installedDevices", ok: false, data: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const message = `installed-devices が失敗しました(exit code: ${String(exitCode)})`;
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = `installed-devices の出力を解析できませんでした: ${String(error)}`;
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      if (!isInstalledDevicesJson(parsed)) {
        const message = "installed-devices の出力形式が不正です。";
        this.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      respond({ type: "installedDevices", ok: true, data: parsed, error: null });
    });
  }

  /**
   * `ftester api create-device` を短命プロセスとして実行する(デバイス追加モーダルの OK)。
   * creatingDevice フラグによる単一実行ガード(実行中に来たリクエストは即座に失敗を返す。
   * モーダル側も自身の作成中状態でボタンを無効化するが、二重の安全策として host 側でも弾く)。
   * finished イベントが来る前にプロセスが終了した場合(クラッシュ等)は合成の失敗結果を送る
   * (executeDeviceOpJob の finishOnce パターンと同じ)。成功時は、machines/*.json の
   * FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
   * 反映を待たせないようここでも明示的に呼ぶ(冪等なので二重呼び出しは無害)。
   * msg.register が false の場合は `--no-register` を付与し、物理作成のみ行う(マシンプロファイルへの
   * 追記はしない。#device-pick-overlay の「+」から開いた新規作成モーダルが使う。2026-07-11 指示)。
   * この場合 postMachineProfileInfo() を呼んでも(何も追記されていないため)実質的に無意味だが、
   * register:true と分岐を分けるほどの理由が無いため呼び出し自体は共通のままにしている。
   */
  private runCreateDevice(msg: CreateDeviceMessage): void {
    if (this.creatingDevice) {
      this.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: "作成処理が既に実行中です。",
        device: null,
      });
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        device: null,
      });
      return;
    }
    const args = [
      "api",
      "create-device",
      "--project",
      resolution.project,
      "--machine",
      msg.machine,
      "--platform",
      msg.platform,
      "--name",
      msg.name,
      "--model",
      msg.model,
      "--os",
      msg.os,
    ];
    if (!msg.register) {
      args.push("--no-register");
    }

    this.creatingDevice = true;
    let responded = false;
    const respond = (
      ok: boolean,
      error: string | null,
      device: { avd: string | null; udid: string | null } | null,
    ): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.creatingDevice = false;
      this.post({ type: "createDeviceResult", ok, name: msg.name, error, device });
      if (ok) {
        this.postMachineProfileInfo();
      }
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})の起動に失敗しました: ${String(error)}`,
      );
      respond(false, String(error), null);
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isCreateDeviceEvent(value)) {
          this.outputChannel.appendLine(
            `[create-device ${msg.name}] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "log") {
          this.outputChannel.appendLine(`[create-device ${msg.name}] ${value.message}`);
        } else {
          if (!value.ok) {
            this.outputChannel.appendLine(
              `[ftester] create-device(${msg.name})が失敗しました: ${value.error ?? "(詳細不明)"}`,
            );
          }
          respond(value.ok, value.error, value.device ? { avd: value.device.avd, udid: value.device.udid } : null);
        }
      },
      (line) => this.outputChannel.appendLine(`[create-device ${msg.name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})の実行でエラーが発生しました: ${error.message}`,
      );
      respond(false, error.message, null);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})が終了しました(exit code: ${String(exitCode)})`,
      );
      // finished を経由せずに落ちたケース(クラッシュ・kill 等)を合成の失敗として扱う。
      // finished 経由で既に respond 済みの場合は no-op(responded ガード)。
      respond(false, `プロセスが exit code ${String(exitCode)} で終了しました`, null);
    });
  }
}

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

/**
 * webview の HTML を生成する。CSS/JS は src/webview/monitor/ から esbuild が media/monitor/ に
 * バンドルした外部ファイル(style.css/main.js)を読み込む(webview.asWebviewUri で変換した URI)。
 * HTML 本文はこれまでどおりこの関数内にインライン生成する。
 */
function renderHtml(webview: vscode.Webview, extensionUri: vscode.Uri): string {
  const nonce = generateNonce();
  const styleUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "monitor", "style.css"));
  const scriptUri = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "monitor", "main.js"));
  const csp = [
    "default-src 'none'",
    "img-src data:",
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div id="tabbar" role="tablist">
    <button id="tab-devices" class="tab-button active" type="button" role="tab" aria-selected="true" aria-controls="panel-devices">デバイス</button>
    <button id="tab-profiles" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-profiles">プロファイル</button>
    <button id="tab-settings" class="tab-button" type="button" role="tab" aria-selected="false" aria-controls="panel-settings">設定</button>
  </div>

  <div id="panel-devices" class="tab-panel" role="tabpanel" aria-labelledby="tab-devices">
    <div id="toolbar" class="toolbar">
      <button id="btn-devices-up">デバイスを全て起動</button>
      <button id="btn-devices-down" class="secondary">全て終了</button>
      <button id="btn-restart" class="secondary">モニター再起動</button>
      <label class="profile-label">実行プロファイル
        <select id="profile-select" title="以後のテスト実行・デバッグ実行と、このモニターの監視対象デバイスに使う実行プロファイル(ftester.profile 設定)" disabled></select>
      </label>
      <!-- ホストMacのメトリクスグラフ(CPU/GPU/ANE/MEM)。host-metrics プロセス(拡張側が1秒間隔で
           常駐 spawn)からの hostMetrics メッセージ受信のたびに再描画する(webview 側は独自タイマーを
           持たない)。データ未着時はグラフ空+値「–」のまま(プレースホルダ不要)。 -->
      <div id="host-metrics" class="host-metrics">
        <span class="host-metric" id="hm-cpu" title="CPU負荷"><span class="hm-label">CPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-gpu" title="GPU負荷"><span class="hm-label">GPU</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-ane" title="ANE負荷"><span class="hm-label">ANE</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
        <span class="host-metric" id="hm-mem" title="メモリ使用量"><span class="hm-label">MEM</span><canvas class="hm-canvas" width="72" height="22"></canvas><span class="hm-value">–</span></span>
      </div>
    </div>
    <div id="banner" class="banner"></div>

    <div id="tile-pane" class="tile-pane">
      <div id="grid" class="grid"></div>
      <div id="empty" class="empty">デバイス情報を待機しています(ポーリング形式のため反映まで数秒かかることがあります)...</div>
    </div>

    <div id="splitter" class="splitter" role="separator" aria-orientation="horizontal" aria-label="タイルと出力の分割境界線"></div>

    <div id="output-pane" class="output-pane">
      <div class="lanes-header">
        <span class="lanes-title">実行ログ</span>
        <span id="lanes-selection-status"></span>
        <span id="lanes-run-status"></span>
      </div>
      <div id="lanes-placeholder" class="lanes-placeholder">テストを実行するとデバイス毎の出力がここに表示されます</div>
      <div id="lanes-grid" class="lanes-grid" style="display: none;"></div>
    </div>
  </div>

  <div id="panel-profiles" class="tab-panel" role="tabpanel" aria-labelledby="tab-profiles" style="display: none;">
    <!-- 単一の縦スクロール(#panel-profiles)になったことで下のセクションまで長くスクロール
         する必要が出たため、常に見えるジャンプリンクを sticky ヘッダとして先頭に置く
         (セクション順=実行/アプリ/マシンプロファイルに合わせた並び)。 -->
    <div id="profile-jump-header" class="profile-jump-header">
      <button type="button" class="profile-jump-link" data-target="run-profile-section">実行プロファイル</button>
      <button type="button" class="profile-jump-link" data-target="app-profile-section">アプリプロファイル</button>
      <button type="button" class="profile-jump-link" data-target="machine-profile-section">マシンプロファイル</button>
    </div>

    <div id="run-profile-section" class="profile-section run-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">実行プロファイル</span>
        <select id="run-profile-select" style="display: none;"></select>
        <span id="run-profile-name-static" class="machine-name-static" style="display: none;">(実行プロファイルなし)</span>
        <!-- 実行プロファイル自体の追加/コピー/削除/名前変更。マシンプロファイルセクション
             (btn-machine-add 等)と同一デザインのインライン SVG アイコンボタン(codicon
             "add"/"copy"/"remove"/"edit" と同一パス)。 -->
        <button id="btn-run-profile-add" class="icon-button" title="実行プロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-run-profile-copy" class="icon-button" title="実行プロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-run-profile-remove" class="icon-button" title="実行プロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-run-profile-rename" class="icon-button" title="実行プロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="run-profile-body" class="run-profile-body">
        <div id="run-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="run-profile-editor" class="run-profile-editor" style="display: none;">
          <div class="modal-row">
            <label for="run-profile-machine">使用するマシンプロファイル<span class="required-badge">必須</span></label>
            <select id="run-profile-machine"></select>
          </div>
          <div class="modal-row">
            <label for="run-profile-app">アプリ</label>
            <select id="run-profile-app"></select>
          </div>
          <div class="modal-row run-profile-devices-row">
            <label>デバイス</label>
            <div id="run-profile-devices" class="run-profile-devices"></div>
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="run-profile-heal">
            <label for="run-profile-heal">自己修復(heal)を有効にする</label>
          </div>
          <div class="modal-row">
            <label for="run-profile-report-dir">reportDir</label>
            <input type="text" id="run-profile-report-dir" placeholder="reports">
          </div>
          <div class="modal-row">
            <label for="run-profile-default-timeout">defaultTimeout</label>
            <input type="text" id="run-profile-default-timeout">
          </div>
          <div id="run-profile-error" class="modal-error"></div>
          <div class="modal-buttons form-buttons">
            <button id="run-profile-confirm" type="button" disabled>確定</button>
            <button id="run-profile-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
          </div>
        </div>
      </div>
    </div>

    <div id="app-profile-section" class="profile-section app-profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">アプリプロファイル</span>
        <select id="app-profile-select" style="display: none;"></select>
        <span id="app-profile-name-static" class="machine-name-static" style="display: none;">(アプリプロファイルなし)</span>
        <!-- アプリプロファイル自体の追加/コピー/削除/名前変更。マシン/実行プロファイルセクション
             と同一デザインのインライン SVG アイコンボタン(codicon "add"/"copy"/"remove"/"edit" と
             同一パス)。 -->
        <button id="btn-app-profile-add" class="icon-button" title="アプリプロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-app-profile-copy" class="icon-button" title="アプリプロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-app-profile-remove" class="icon-button" title="アプリプロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-app-profile-rename" class="icon-button" title="アプリプロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div id="app-profile-body" class="app-profile-body">
        <div id="app-profile-placeholder" class="profile-detail-placeholder" style="display: none;"></div>
        <div id="app-profile-editor" class="app-profile-editor" style="display: none;">
          <!-- 共通グループは表示名(appName)+自動インストール(autoInstall)。app/appPath は廃止済み
               (ランタイムは common の app/appPath を無視し、ios/android 側でのみ指定できる新仕様の
               ため。フォームにも入力欄自体を置かない)。自動インストールは以前 ios/android
               セクション別だったが、共通でのみ設定できる仕様に一本化した(2026-07-11 指示)ため、
               チェックボックスはこの共通グループにのみ置く。既定OFF(無効)。heal 行と同じ
               マークアップ・スタイル([チェックボックス]+[ラベル]の横並び1行)。 -->
          <div class="app-profile-group-title">共通</div>
          <div class="modal-row">
            <label for="app-profile-common-app-name">表示名</label>
            <input type="text" id="app-profile-common-app-name">
          </div>
          <div class="modal-row profile-checkbox-row">
            <input type="checkbox" id="app-profile-common-auto-install">
            <label for="app-profile-common-auto-install">自動インストールを有効にする</label>
          </div>

          <div class="app-profile-group-title app-profile-group-title-ios">iOS</div>
          <div class="modal-row">
            <label for="app-profile-ios-app-name">表示名</label>
            <input type="text" id="app-profile-ios-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app">アプリID</label>
            <input type="text" id="app-profile-ios-app" placeholder="bundle id">
          </div>
          <div class="modal-row">
            <label for="app-profile-ios-app-path">パッケージパス</label>
            <input type="text" id="app-profile-ios-app-path">
          </div>

          <div class="app-profile-group-title app-profile-group-title-android">Android</div>
          <div class="modal-row">
            <label for="app-profile-android-app-name">表示名</label>
            <input type="text" id="app-profile-android-app-name">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app">アプリID</label>
            <input type="text" id="app-profile-android-app" placeholder="パッケージ名">
          </div>
          <div class="modal-row">
            <label for="app-profile-android-app-path">パッケージパス</label>
            <input type="text" id="app-profile-android-app-path">
          </div>

          <div id="app-profile-error" class="modal-error"></div>
          <div class="modal-buttons form-buttons">
            <button id="app-profile-confirm" type="button" disabled>確定</button>
            <button id="app-profile-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
          </div>
        </div>
      </div>
    </div>

    <div id="machine-profile-section" class="profile-section">
      <div class="profile-toolbar">
        <span class="profile-toolbar-title">マシンプロファイル</span>
        <select id="machine-select" style="display: none;"></select>
        <span id="machine-name-static" class="machine-name-static" style="display: none;"></span>
        <!-- マシンプロファイル自体の追加/削除/名前変更。codicon フォントは CSP(外部リソース不可)で
             読み込めないため、codicon "add"/"remove"/"edit" と同一パスのインライン SVG を使う
             (btn-device-add と同じ方針)。 -->
        <button id="btn-machine-add" class="icon-button" title="マシンプロファイルの追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
        <button id="btn-machine-copy" class="icon-button" title="マシンプロファイルのコピー" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 4l1-1h5.414L14 6.586V14l-1 1H5l-1-1V4zm9 3l-3-3H5v10h8V7zM3 1L2 2v10l1 1V2h6.414l-1-1H3z"/></svg></button>
        <button id="btn-machine-remove" class="icon-button" title="マシンプロファイルの削除" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M15 8H1V7h14v1z"/></svg></button>
        <button id="btn-machine-rename" class="icon-button" title="マシンプロファイル名の変更" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M13.23 1h-1.46L3.52 9.25l-.16.22L1 13.59 2.41 15l4.12-2.36.22-.16L15 4.23V2.77L13.23 1zM2.41 13.59l1.51-3 1.45 1.45-2.96 1.55zm3.83-2.06L4.47 9.76l8-8 1.77 1.77-8 8z"/></svg></button>
      </div>
      <div class="profile-actions">
        <!-- デバイス追加ボタンは2種類(要件1): 新規シミュレータ/AVDを作成して追加(従来の
             #device-add-overlay を開く)と、既にローカルにインストール済みのシミュレータ/AVDから
             選んで追加(新設の #device-pick-overlay を開く)。見た目は .icon-button の亜種
             (.with-label。アイコン=codicon add の SVG+テキストラベルの横並び)。 -->
        <!-- 「+新規作成」ボタンは廃止(2026-07-11 指示)。新規作成は「+」で開く選択画面内の
             「+」から行う。ラベル「デバイス」で「+」が何の追加かを示す。 -->
        <span class="profile-actions-label">デバイス</span>
        <button id="btn-device-add-existing" class="icon-button" title="インストール済みのシミュレータ/AVDからマシンプロファイルに追加" disabled><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="machine-profile-error" class="profile-error" style="display: none;"></div>
      <div id="machine-profile-body" class="profile-body">
        <div id="machine-device-list" class="machine-device-list"></div>
        <div id="machine-device-detail-pane" class="machine-device-detail-pane">
          <div id="profile-detail-placeholder" class="profile-detail-placeholder">デバイスを選択すると内容を表示します</div>
          <div id="machine-device-editor" class="machine-device-editor" style="display: none;">
            <div class="machine-device-editor-header">
              <span id="editor-device-name" class="tile-name"></span>
              <span id="editor-device-platform" class="editor-platform-label"></span>
            </div>
            <!-- 編集可否の制御(ユーザー指定): 機種/OS/UDID/AVD は作成済みデバイスの実体を指す
                 属性で API では変更できない(変更にはデバイスの除去→作り直しが必要)ため、
                 テキストボックスではなくラベル(選択・コピー可能なテキスト)で表示する。
                 名前(プロファイル上の論理名)とポート(ブリッジポート設定)はプロファイル側の
                 設定値なので編集可。ラベルは input イベントを発火しないので dirty 判定にも入らず、
                 確定時は元の値がそのまま往復する。 -->
            <div class="modal-row">
              <label for="editor-name">名前</label>
              <input type="text" id="editor-name">
            </div>
            <div id="editor-ios-fields">
              <div class="modal-row">
                <label>機種</label>
                <span id="editor-simulator" class="editor-readonly-value" title="機種は変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
              <div class="modal-row">
                <label>OS</label>
                <span id="editor-os" class="editor-readonly-value" title="OSは変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
              <div class="modal-row">
                <label>UDID</label>
                <span id="editor-udid" class="editor-readonly-value" title="UDIDは作成時に決まる識別子のため変更できません"></span>
              </div>
              <div class="modal-row">
                <label for="editor-port">ポート</label>
                <input type="text" id="editor-port">
              </div>
            </div>
            <div id="editor-android-fields">
              <div class="modal-row">
                <label>AVD</label>
                <span id="editor-avd" class="editor-readonly-value" title="AVDは変更できません(変更するにはデバイスを除去して作り直してください)"></span>
              </div>
            </div>
            <div id="editor-error" class="modal-error"></div>
            <div class="modal-buttons form-buttons">
              <button id="editor-confirm" type="button" disabled>確定</button>
              <button id="editor-cancel" class="secondary" type="button" style="display: none;">キャンセル</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div id="panel-settings" class="tab-panel" role="tabpanel" aria-labelledby="tab-settings" style="display: none;">
    <div class="tab-placeholder">このタブは準備中です(設定機能を今後追加予定)</div>
  </div>

  <div id="device-op-menu" class="device-op-menu" role="menu">
    <button id="device-op-menu-item" class="device-op-menu-item" type="button" role="menuitem"></button>
  </div>

  <!-- プロファイルタブのデバイス行右クリックメニュー(除去のみ。プロファイルから外すだけで本体は
       消さないため、文言は「削除」ではなく「除去」。2026-07-11 ユーザー指示)。見た目・挙動は
       #device-op-menu と同じクラスを共用する(独立した表示状態・DOM要素)。 -->
  <div id="machine-device-menu" class="device-op-menu" role="menu">
    <button id="machine-device-menu-item" class="device-op-menu-item" type="button" role="menuitem">除去</button>
  </div>

  <div id="device-add-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-add-title">
      <div id="device-add-title" class="modal-title">デバイスを追加</div>
      <div class="modal-row">
        <label>OS種別</label>
        <div class="modal-radio-group">
          <label class="modal-radio"><input type="radio" id="dlg-platform-ios" name="dlg-platform" value="ios" checked>iOS</label>
          <label class="modal-radio"><input type="radio" id="dlg-platform-android" name="dlg-platform" value="android">Android</label>
        </div>
      </div>
      <div class="modal-row">
        <label for="dlg-model">モデル</label>
        <select id="dlg-model"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-os">OSバージョン</label>
        <select id="dlg-os"></select>
      </div>
      <div class="modal-row">
        <label for="dlg-name">デバイス名</label>
        <input type="text" id="dlg-name">
      </div>
      <div id="dlg-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="dlg-cancel" class="secondary" type="button">キャンセル</button>
        <button id="dlg-ok" type="button">OK</button>
      </div>
    </div>
  </div>

  <!-- 名前入力モーダル(#name-input-overlay)。実行/アプリ/マシンプロファイルの追加・コピー・
       名前変更(9箇所、拡張側 promptName)を共通で担う、showInputBox 相当の置き換え。
       #device-add-overlay と同じオーバーレイ/ダイアログ様式。拡張側からの nameInputOpen で
       タイトル・初期値・検証パラメータ(noun/dupLabel/existing/caseInsensitiveDup)を受け取り、
       OK/キャンセルはそれぞれ nameInputConfirm/nameInputCancel を id 付きで返す(拡張側の
       pendingNameInput と突き合わせる)。 -->
  <div id="name-input-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="name-input-title">
      <div id="name-input-title" class="modal-title"></div>
      <div class="modal-row">
        <input type="text" id="name-input-field">
      </div>
      <div id="name-input-error" class="modal-error"></div>
      <div class="modal-buttons">
        <button id="name-input-cancel" class="secondary" type="button">キャンセル</button>
        <button id="name-input-ok" type="button">OK</button>
      </div>
    </div>
  </div>

  <!-- 「+既存から選択」モーダル(要件2)。#device-add-overlay と同じオーバーレイ/ダイアログ様式。
       中身は iOS シミュレータ/Android AVD の2グループ(#device-pick-ios-group/-android-group。
       中身は JS が installedDevices 受信時に組み立てる)。実機で数十件規模になる前提のため
       一覧領域(.device-pick-list)だけを固定上限でスクロールさせる(コーディネーター指示)。
       各行のチェックボックスは「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表し、
       登録済みなら初期チェック(disabled/淡色化はしない。常に操作可能)。OK は初期状態からの
       差分がある間だけ有効になる(devicePickOk の disabled 切り替えは JS 側)。タイトル行右端の
       「+」ボタン(#device-pick-add-new)はこのモーダルを閉じずに #device-add-overlay を上に
       重ねて開く(z-index は上の #device-add-overlay ルールを参照)。フッターの注記は、チェックを
       外すことが「登録解除」であって実体(シミュレータ/AVD 本体)の削除ではないことを常時明示する。 -->
  <div id="device-pick-overlay" class="modal-overlay">
    <div class="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="device-pick-title">
      <div class="modal-title device-pick-title-row">
        <span id="device-pick-title">既存のデバイスから選択</span>
        <button id="device-pick-add-new" class="icon-button" type="button" title="デバイスを新規作成"><svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"/></svg></button>
      </div>
      <div id="device-pick-list" class="device-pick-list">
        <div id="device-pick-ios-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-ios-title">iOS シミュレータ</div>
          <div id="device-pick-ios-body" class="device-pick-group-body"></div>
        </div>
        <div id="device-pick-android-group" class="device-pick-group">
          <div class="device-pick-group-title" id="device-pick-android-title">Android AVD</div>
          <div id="device-pick-android-body" class="device-pick-group-body"></div>
        </div>
      </div>
      <div id="device-pick-error" class="modal-error"></div>
      <div class="device-pick-note">チェックを外して OK すると登録解除されます(シミュレータ/AVD 本体は削除されません)</div>
      <div class="modal-buttons">
        <button id="device-pick-cancel" class="secondary" type="button">キャンセル</button>
        <button id="device-pick-ok" type="button" disabled>OK</button>
      </div>
    </div>
  </div>

  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
