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
  MAX_LANE_LINES,
  OVERALL_LANE_ID,
  OVERALL_LANE_NAME,
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

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = new MonitorPanelController(workspaceRoot, getConfig, outputChannel, eventBus);
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
    });
    this.panel = panel;
    panel.webview.html = renderHtml();

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.stopMonitorProcess();
    });

    this.startMonitorProcess();
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
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage): void {
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

/** webview の HTML をインライン生成する。外部リソースは一切読み込まない(CSP: default-src 'none')。 */
function renderHtml(): string {
  const nonce = generateNonce();
  const csp = [
    "default-src 'none'",
    "img-src data:",
    "style-src 'unsafe-inline'",
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>${PANEL_TITLE}</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  html, body {
    height: 100%;
  }
  body {
    margin: 0;
    padding: 0;
    font-family: var(--vscode-font-family, sans-serif);
    font-size: var(--vscode-font-size, 13px);
    color: var(--vscode-foreground);
    background-color: var(--vscode-editor-background);
    /* パネル全体を上下2ペイン([タイル][スプリッター][出力])の flex column にし、
       body 自体はスクロールさせない(各ペイン内でスクロールする)。 */
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
  }
  /* タブバー(VS Code のエディタタブ風)。body 直下、タブパネル群の手前に置く。
     以前は「背景透明+文字色+1px下線」のパネルタイトル風デザインだったが視認性が低かった
     (ユーザー報告)ため、エディタタブと同じくアクティブ/非アクティブを背景色の差で
     区別するデザインに変更する。 */
  #tabbar {
    flex: 0 0 auto;
    display: flex;
    gap: 0;
    padding: 0;
    background-color: var(--vscode-editorGroupHeader-tabsBackground, transparent);
    border-bottom: 1px solid var(--vscode-tab-border, var(--vscode-panel-border, transparent));
  }
  /* 既存の button {...} グローバルスタイル(背景色・ボーダー・padding)の影響を受けないよう、
     #tabbar 配下限定のセレクタで明示的に上書きする(具体度をグローバル規則より高くする狙い)。 */
  #tabbar .tab-button {
    font-family: inherit;
    font-size: inherit;
    padding: 8px 18px;
    margin: 0;
    border: none;
    border-right: 1px solid var(--vscode-tab-border, transparent);
    border-top: 1px solid transparent;
    border-radius: 0;
    background-color: var(--vscode-tab-inactiveBackground, transparent);
    color: var(--vscode-tab-inactiveForeground, var(--vscode-descriptionForeground));
    cursor: pointer;
  }
  #tabbar .tab-button:hover:not(.active) {
    background-color: var(--vscode-tab-hoverBackground, var(--vscode-toolbar-hoverBackground, rgba(90, 93, 94, 0.31)));
    color: var(--vscode-tab-activeForeground, var(--vscode-foreground));
  }
  #tabbar .tab-button.active {
    background-color: var(--vscode-tab-activeBackground, var(--vscode-editor-background));
    color: var(--vscode-tab-activeForeground, var(--vscode-foreground));
    /* アクティブは上端の1本線(エディタタブと同じ)で示す。 */
    border-top-color: var(--vscode-tab-activeBorderTop, var(--vscode-focusBorder, #007acc));
  }
  /* デバイス/プロファイル/設定の各タブパネルの共通コンテナ。非アクティブなものは JS が
     inline style で display:none にする(タブ切替直後にスプリッター高さの再計算が同期的に
     必要なため、クラス経由ではなく inline style で即座に反映させる)。 */
  .tab-panel {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  /* プロファイル/設定タブの準備中プレースホルダー。.empty と同じ配色・文字サイズで中央寄せ
     (タブパネル内で唯一の子要素なので、.empty のような absolute inset は不要)。 */
  .tab-placeholder {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  .toolbar {
    flex: 0 0 auto;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    padding: 12px 12px 0 12px;
  }
  button {
    font-family: inherit;
    font-size: inherit;
    padding: 4px 10px;
    border: 1px solid var(--vscode-button-border, transparent);
    border-radius: 2px;
    background-color: var(--vscode-button-background);
    color: var(--vscode-button-foreground);
    cursor: pointer;
  }
  button:hover:not(:disabled) { background-color: var(--vscode-button-hoverBackground); }
  button:disabled { opacity: 0.5; cursor: default; }
  /* 非活性の primary ボタン(確定/OK 等)は、既定だと青背景が opacity 0.5 で半透明になるだけで
     「押せそう」に見えるため、背景を薄いグレーにする(2026-07-11 ユーザー指示)。セレクタを
     :not([class]) にするのは、確定/OK 等の primary ボタンはいずれも class 無しで、
     .icon-button/.secondary/.tab-button/.device-op-menu-item 等 class 付きボタンは各自の
     disabled 表現を持つため巻き込まないようにするため。button:disabled(0,1,1)より
     詳細度が高い(0,2,1)ので背景・文字色だけ確実に上書きされ、opacity: 0.5 は上の
     button:disabled から引き続き適用される。 */
  button:not([class]):disabled {
    background-color: var(--vscode-button-secondaryBackground, rgba(128, 128, 128, 0.3));
    color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
  }
  /* プロファイルタブの確定ボタンは非活性時は完全に透明にする(2026-07-11 ユーザー指示。
     要素は残してレイアウト(操作行の高さ・キャンセルボタンの位置)を確保する。
     モーダルの OK(#dlg-ok/#device-pick-ok)は消えると存在に気づけないため上のグレー表現のまま)。 */
  #run-profile-confirm:disabled,
  #app-profile-confirm:disabled,
  #editor-confirm:disabled {
    background-color: transparent;
    border-color: transparent;
    color: transparent;
  }
  button.secondary {
    background-color: var(--vscode-button-secondaryBackground, transparent);
    color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
  }
  button.secondary:hover:not(:disabled) {
    background-color: var(--vscode-button-secondaryHoverBackground, var(--vscode-toolbar-hoverBackground));
  }
  /* VS Code のツールバーアイコンボタン(エディタタブ横の「+」等)と同じ見た目にする。
     グローバルな button/.secondary のスタイルより優先させるためクラスセレクタで上書きする
     (デバイス追加+マシンプロファイル追加/コピー/削除/名前変更+アプリプロファイル追加/コピー/
     削除/名前変更+実行プロファイル追加/コピー/削除/名前変更の計13ボタン共通)。 */
  .icon-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: none;
    border-radius: 5px;
    background-color: transparent;
    color: var(--vscode-icon-foreground, var(--vscode-foreground));
  }
  .icon-button:hover:not(:disabled) {
    background-color: var(--vscode-toolbar-hoverBackground, rgba(90, 93, 94, 0.31));
  }
  /* .icon-button の亜種: アイコン(codicon add の SVG)+テキストラベルの横並びボタン
     (「+新規作成」「+既存から選択」の2ボタン。要件1)。.icon-button の正方形寸法(22px)は
     ラベル文字が入らないため、幅だけ auto にして左右 padding・アイコンとラベルの gap を足す
     (高さ・角丸・背景・hover 色は .icon-button の寸法感をそのまま維持する)。 */
  .icon-button.with-label {
    width: auto;
    padding: 0 8px;
    gap: 4px;
  }
  .profile-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  select {
    font-family: inherit;
    font-size: inherit;
    padding: 2px 6px;
    border-radius: 2px;
    background-color: var(--vscode-dropdown-background);
    color: var(--vscode-dropdown-foreground);
    border: 1px solid var(--vscode-dropdown-border);
  }
  select:disabled { opacity: 0.5; cursor: default; }
  .status {
    margin-left: auto;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .banner {
    flex: 0 0 auto;
    display: none;
    padding: 8px 10px;
    margin: 12px 12px 0 12px;
    border-radius: 3px;
    background-color: var(--vscode-inputValidation-errorBackground, #5a1d1d);
    border: 1px solid var(--vscode-inputValidation-errorBorder, #be1100);
    color: var(--vscode-foreground);
    white-space: pre-wrap;
    font-size: 12px;
  }
  .banner.visible { display: block; }
  .tile-pane {
    /* 高さは JS(スプリッタードラッグ/初期化/復元)が inline style で設定する。
       最小値は JS 側でクランプする(要件: 上下それぞれ最小120px程度)。
       余白は子要素(.grid/.empty)の inset で付けるので、ここでは padding を持たない。 */
    flex: 0 0 auto;
    position: relative;
    overflow: hidden;
  }
  .grid {
    position: absolute;
    inset: 12px 12px 0 12px;
    display: flex;
    flex-wrap: nowrap;
    /* タイルが上ペインの高さいっぱいに伸びる(タイル高さフィットの土台)。 */
    align-items: stretch;
    gap: 8px;
    /* auto だとあふれた時しかバーが出ないため、常時表示の指定(scroll)にする */
    overflow-x: scroll;
    overflow-y: hidden;
    /* 横スクロールバー分の余白を確保する */
    padding-bottom: 10px;
  }
  /* 横スクロールバーを常時表示する(webview は Chromium なので、::-webkit-scrollbar を
     明示的にスタイルすることで、OS のオーバーレイ式スクロールバー(操作しないと自動的に
     フェードアウトする)ではなくクラシック表示になり、常に見える状態を保てる)。
     トラックにも薄い背景色を付け、あふれていない(つまみが無い)ときもバーの位置が見えるようにする。
     色は VSCode のスクロールバー用テーマ変数に合わせる。 */
  .grid::-webkit-scrollbar {
    height: 12px;
  }
  .grid::-webkit-scrollbar-track {
    /* つまみ(テーマ変数)より薄い固定の半透明グレー(ライト/ダーク両テーマで視認可) */
    background-color: rgba(121, 121, 121, 0.15);
    border-radius: 6px;
  }
  .grid::-webkit-scrollbar-thumb {
    background-color: var(--vscode-scrollbarSlider-background, rgba(121, 121, 121, 0.4));
    border-radius: 6px;
  }
  .grid::-webkit-scrollbar-thumb:hover {
    background-color: var(--vscode-scrollbarSlider-hoverBackground, rgba(100, 100, 100, 0.7));
  }
  .grid::-webkit-scrollbar-thumb:active {
    background-color: var(--vscode-scrollbarSlider-activeBackground, rgba(191, 191, 191, 0.4));
  }
  .tile {
    /* 固定幅は廃止。高さ = グリッド(上ペイン)の高さいっぱいに stretch し、
       幅はフレーム画像のアスペクト比(frame-wrap 側)に応じて内容が決める(fit-content)。 */
    flex: 0 0 auto;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
    padding: 8px;
    background-color: var(--vscode-sideBar-background, var(--vscode-editor-background));
    display: flex;
    flex-direction: column;
    gap: 6px;
    /* クリックでレーン絞り込みの選択ができるが、カーソルは通常のまま(ユーザー指定) */
  }
  .tile.selected {
    border-color: var(--vscode-focusBorder, #007acc);
    border-width: 2px;
    padding: 7px;
  }
  /* ヘッダー・フッターのテキスト行はタイルの幅の決定に寄与させない
     (width:0 + min-width:100% で「フレーム画像が決めた幅」に従わせる)。
     これが無いとバッジ列や省略前のエラーテキストの固有幅でタイルが画像より
     広がり、左右に大きな余白ができて一列に並ぶ台数が減る(ユーザー報告)。 */
  .tile-header,
  .tile-footer {
    width: 0;
    min-width: 100%;
  }
  /* ヘッダーは固定高(スプリッター位置に関わらず文字が潰れない。ユーザー指定)。
     detail/updated/error も固定高で常時スロットを確保し、タイルの「画像以外の高さ」を
     定数化する(JS の relayoutTiles() の TILE_CHROME_HEIGHT と一致させること)。 */
  .tile-header {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: nowrap;
    overflow: hidden;
    flex: 0 0 20px;
    height: 20px;
  }
  /* デバイス名: プラットフォームバッジは廃止し、名前自体を同じスタイルで装飾する
     (iOS=水色/Android=Androidブランド緑、文字は白。ユーザー指定) */
  .tile-name {
    font-weight: 600;
    font-size: 12px;
    flex: 0 1 auto;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    padding: 1px 8px;
    border-radius: 10px;
    color: #ffffff;
  }
  .tile-name-ios { background-color: #29b6f6; }
  .tile-name-android { background-color: #3ddc84; }
  .badge {
    font-size: 11px;
    padding: 1px 6px;
    border-radius: 10px;
    white-space: nowrap;
  }
  /* 状態表示は装飾なしのプレーンテキスト(ユーザー指定) */
  .tile-state {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    white-space: nowrap;
  }
  .badge-running {
    background-color: var(--vscode-charts-blue, #0078d4);
    color: #ffffff;
    display: none;
    /* デバイス名が縮んでも右端に寄せる */
    margin-left: auto;
  }
  .frame-wrap {
    /* 高さフィット: 画像に使える高さ(--tile-image-h)は JS の relayoutTiles() が
       タイルの実測高さから算出して grid に設定する。幅は実フレームのアスペクト比
       (--tile-aspect、フレーム受信時にタイルへ設定。既定は 9/19.5)から計算する。
       これにより「タイル幅 = 画像幅 + 固定マージン(padding)」になり、
       画像の自然サイズ(960px配信で幅442px等)が固有幅としてタイルを
       押し広げることがない(横に並ぶ台数を最大化する。ユーザー指定)。 */
    flex: 0 0 auto;
    align-self: center;
    position: relative;
    height: var(--tile-image-h, 240px);
    width: calc(var(--tile-image-h, 240px) * var(--tile-aspect, 0.4615));
    background-color: var(--vscode-input-background, #1e1e1e);
    /* 画像の輪郭が分かるよう、細くて濃いめのグレーの実線(ユーザー指定) */
    border: 1px solid #757575;
    border-radius: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
  }
  .frame-wrap img {
    /* 絶対配置にして、img の自然サイズが intrinsic 幅の計算に寄与しないようにする */
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    display: block;
  }
  .frame-placeholder {
    color: var(--vscode-descriptionForeground);
    font-size: 12px;
    text-align: center;
    padding: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
  }
  /* プレースホルダー左側の状態アイコン(未起動=電源アイコン / 起動中=スピナー) */
  .placeholder-icon {
    width: 14px;
    height: 14px;
    flex: none;
    display: block;
  }
  .placeholder-icon.offline {
    color: var(--vscode-descriptionForeground);
  }
  .placeholder-icon.booting {
    box-sizing: border-box;
    border-radius: 50%;
    border: 2px solid rgba(226, 185, 61, 0.25);
    border-top-color: var(--vscode-charts-yellow, #e2b93d);
    animation: ft-placeholder-spin 1s linear infinite;
  }
  @keyframes ft-placeholder-spin {
    to { transform: rotate(360deg); }
  }
  /* タイル右クリックメニューでの起動/停止操作中バッジ(画像左上に重ねる)。
     ボタンを廃止した代わりの実行中表示(要件3)。frame-wrap は renderFrame() が
     textContent='' で中身を作り直すため、このバッジも毎回末尾に再アペンドされる
     (表示可否はこの要素の 'visible' クラスで独立して管理する)。 */
  .tile-op-badge {
    position: absolute;
    top: 4px;
    left: 4px;
    z-index: 1;
    font-size: 10px;
    padding: 1px 6px;
    border-radius: 10px;
    background-color: var(--vscode-badge-background, #6e6e6e);
    color: var(--vscode-badge-foreground, #ffffff);
    white-space: nowrap;
    display: none;
    pointer-events: none;
  }
  .tile-op-badge.visible { display: inline-block; }
  /* フッター(1行固定): [状態バッジ] [HH:MM:SS] [⚠エラー(あれば、省略表示)] */
  .tile-footer {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: 0 0 18px;
    height: 18px;
    overflow: hidden;
  }
  .tile-updated {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    white-space: nowrap;
    /* 時刻は右寄せ(ユーザー指定)。中間のエラー要素が空でも右端に寄るように */
    margin-left: auto;
  }
  .tile-error {
    flex: 1 1 auto;
    min-width: 0;
    font-size: 11px;
    color: var(--vscode-errorForeground, #f14c4c);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .empty {
    position: absolute;
    inset: 12px 12px 0 12px;
    display: none;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  /* 上下ペインの分割境界線。ドラッグで .tile-pane の高さを調整する(要件2)。
     常時視認できる色を付ける(ユーザー指定。ホバー/ドラッグでアクセント色に変化)。 */
  .splitter {
    flex: 0 0 6px;
    height: 6px;
    cursor: row-resize;
    background-color: var(--vscode-scrollbarSlider-background, rgba(121, 121, 121, 0.4));
    border-radius: 3px;
  }
  .splitter:hover,
  .splitter.dragging {
    background-color: var(--vscode-focusBorder, #007acc);
  }
  .output-pane {
    /* 出力ペイン(下側)= 常設エリア。残りの縦スペースを全て占有し、内部でスクロールする。 */
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    padding: 8px 12px 12px 12px;
    overflow: hidden;
  }
  .lanes-header {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 8px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .lanes-title {
    font-weight: 600;
    color: var(--vscode-foreground);
  }
  .lanes-placeholder {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  .lanes-grid {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    display: grid;
    /* minmax(0, 1fr) = 列数が増えてもコンテナ幅に収めて等分する(全レーンが常に見える)。
       固定min幅(240px等)だと5台選択時に右端のレーンが画面外に見切れる */
    grid-template-columns: repeat(1, minmax(0, 1fr));
    gap: 10px;
    /* align-content は既定(stretch)のまま = 1行だけの行が出力ペインの下端まで伸びる
       (start にすると下半分が余白になる) */
  }
  .lane {
    display: flex;
    flex-direction: column;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
    overflow: hidden;
    min-height: 160px;
    min-width: 0;
  }
  .lane-header {
    padding: 4px 8px;
    background-color: var(--vscode-sideBar-background, var(--vscode-editor-background));
    border-bottom: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    white-space: nowrap;
    overflow: hidden;
  }
  /* レーン名はデバイスタイルのタイトルと同じ表現(色付きピル、.tile-name-ios/-android を共用) */
  .lane-name {
    display: inline-block;
    font-weight: 600;
    font-size: 12px;
    padding: 1px 8px;
    border-radius: 10px;
    color: #ffffff;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .lane-name-neutral {
    background-color: var(--vscode-badge-background, #6e6e6e);
    color: var(--vscode-badge-foreground, #ffffff);
  }
  .lane-body {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 4px 8px;
    font-family: var(--vscode-editor-font-family, monospace);
    font-size: 11px;
    background-color: var(--vscode-editor-background);
  }
  .lane-line {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    line-height: 1.4;
  }
  /* タイル右クリックの起動/停止メニュー(VS Code Webview は native メニューを使えないため
     div で自作する)。1タイルにつき1項目(起動 or 停止)のみ。マウス位置に表示し、
     JS(openDeviceOpMenu)が画面端で座標をクランプする。
     同じ見た目・挙動をプロファイルタブのデバイス行右クリックメニュー(#machine-device-menu)
     にも流用する(クラスを共用し、要素・状態(表示中エントリ)は独立させる)。 */
  .device-op-menu {
    position: fixed;
    z-index: 1000;
    display: none;
    min-width: 140px;
    padding: 4px;
    border-radius: 4px;
    background-color: var(--vscode-menu-background, var(--vscode-dropdown-background, #252526));
    color: var(--vscode-menu-foreground, var(--vscode-foreground));
    border: 1px solid var(--vscode-menu-border, var(--vscode-widget-border, var(--vscode-panel-border)));
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
  }
  .device-op-menu.visible { display: block; }
  .device-op-menu-item {
    display: block;
    width: 100%;
    text-align: left;
    font-family: inherit;
    font-size: inherit;
    padding: 5px 10px;
    border: none;
    border-radius: 3px;
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .device-op-menu-item:hover:not(:disabled) {
    background-color: var(--vscode-menu-selectionBackground, var(--vscode-list-hoverBackground));
    color: var(--vscode-menu-selectionForeground, inherit);
  }
  .device-op-menu-item:disabled { opacity: 0.6; cursor: default; }

  /* ---- プロファイルタブ: ペイン全体を1つの縦スクロールにする ----------------------------
     以前はマシン/アプリ/実行プロファイルの3セクションを .tab-panel の高さで均等(3等分)に
     分け合い、各セクションが個別にスクロールしていたが、内容が少ないセクションでも常に
     スクロール領域だけ確保されてしまい不格好だった(ユーザー報告)。#panel-profiles 自体を
     縦スクロールコンテナにし、アプリ/実行プロファイルセクションは内容の自然高さのまま積む。
     マシンプロファイルセクションだけは左右2ペイン(デバイス一覧+詳細。スプリッターは廃止し
     一覧幅は内容に自動フィット)という構造上、自然高さにはできないため固定高さ(340px)のまま内部で個別にスクロール
     させる(machine-profile-body・machine-device-editor は従来どおり individually
     overflow-y: auto)。DOM順は上から実行/アプリ/マシンプロファイル(ユーザー報告により、
     使用頻度が高い実行プロファイルを先頭に変更)。 */
  #panel-profiles {
    overflow-y: auto;
  }
  .profile-section {
    min-height: 0;
    display: flex;
    flex-direction: column;
    /* sticky な .profile-jump-header の高さ分だけジャンプ時のスクロール位置がめり込むのを
       防ぐ(scrollIntoView はデフォルトで要素の上端をビューポート上端に合わせるため、sticky
       ヘッダの裏に隠れてしまう)。ヘッダの実高さ(padding 6px×2+1行+border 1px)より
       余裕を持たせた値。 */
    scroll-margin-top: 40px;
  }
  /* 先頭(実行プロファイル)には border-top を付けない。アプリ/マシンプロファイルは前の
     セクションとの区切り線として付ける(セクション順の変更に伴い、以前は
     マシンプロファイル=先頭でborder無し・アプリ/実行=borderありだったのを反転)。 */
  .run-profile-section {
    flex: 0 0 auto;
  }
  .app-profile-section {
    flex: 0 0 auto;
    border-top: 1px solid var(--vscode-panel-border, transparent);
  }
  #machine-profile-section {
    flex: 0 0 auto;
    border-top: 1px solid var(--vscode-panel-border, transparent);
    /* 高さはコンテンツ(デバイス一覧)に応じて伸びる(一覧の内部スクロールは廃止し、
       ペイン全体の単一スクロールで全デバイスを確認できるようにする。ユーザー指定)。
       デバイス0件・フォーム非表示時に潰れないよう最小高さだけ確保する。 */
    min-height: 180px;
  }

  /* ---- プロファイルタブ: 固定ヘッダ(セクションへのジャンプリンク) ---------------------
     #panel-profiles が単一の縦スクロールになったことで、下にスクロールすると目的のセクション
     まで長くスクロールする必要があった(ユーザー報告)。position: sticky で常に上部に
     貼り付くヘッダを置き、3セクションへのテキストリンクを常設する(全セクションの前=
     スクロールコンテナ直下)。 */
  .profile-jump-header {
    position: sticky;
    top: 0;
    z-index: 10;
    background-color: var(--vscode-editor-background);
    border-bottom: 1px solid var(--vscode-panel-border, transparent);
    padding: 6px 12px;
    display: flex;
    gap: 16px;
    flex: 0 0 auto;
  }
  /* テキストリンク風の見た目にする。button 要素で実装しているため、グローバルな button
     スタイル(背景色・枠線・padding。上の button ルール群)を打ち消す必要がある。hover 時の
     背景色は button:hover:not(:disabled) の specificity(要素+2擬似クラス)に勝つよう、
     こちらも要素セレクタ button を含めて specificity を揃える。 */
  button.profile-jump-link {
    background: none;
    border: none;
    padding: 0;
    cursor: pointer;
    color: var(--vscode-textLink-foreground, #3794ff);
    font-size: inherit;
  }
  button.profile-jump-link:hover:not(:disabled) {
    background-color: transparent;
    text-decoration: underline;
    color: var(--vscode-textLink-activeForeground, var(--vscode-textLink-foreground, #3794ff));
  }

  /* ---- プロファイルタブ: マシンプロファイルセクション ---------------------------------- */
  /* 2026-07-11 ユーザー指示で薄いグレー背景のヘッダーバーに変更(実行/アプリ/マシン
     プロファイルの3ヘッダー共通)。当初 sideBarSectionHeader-background を使ったが、
     Light Modern 等のライトテーマでは #F8F8F8(ほぼ白)でパネル背景と区別できなかった
     (2026-07-11 ユーザー報告)ため、タブバー(#tabbar)と同じ
     editorGroupHeader-tabsBackground に変更(どのテーマでもパネル背景よりワントーン濃く、
     拡張内のタブバーと配色が揃う)。背景がバー状に見えるよう padding も
     12px 12px 6px(下だけ元々6pxだった)から上下対称の 6px 12px に変更。 */
  .profile-toolbar {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    background-color: var(--vscode-editorGroupHeader-tabsBackground, rgba(128, 128, 128, 0.15));
  }
  .profile-toolbar-title {
    font-weight: 600;
  }
  /* タイトル行の下の操作行(「+」=デバイスの追加)。デバイス一覧の左端に揃える。 */
  .profile-actions {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 12px 6px;
  }
  /* 「+」の左のラベル(この「+」が何の追加かを示す。2026-07-11 指示で「デバイス」)。 */
  .profile-actions-label {
    font-weight: 600;
  }
  /* machines が1件以上のときは常に表示する(1件でも切替可能なドロップダウンにする。
     0件のときだけ machine-name-static「(マシンプロファイルなし)」を使う)。 */
  #machine-select {
    max-width: 220px;
  }
  .machine-name-static {
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .profile-body {
    flex: 1 1 auto;
    display: flex;
    min-height: 0;
    /* 一覧と右ペインの間の余白は gap ではなく .machine-device-detail-pane の padding-left で
       確保する(スプリッター廃止(2026-07-11)後も方針は同じ)。 */
    gap: 0;
    padding: 0 12px 12px 12px;
  }
  .profile-error {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  .machine-device-list {
    /* 2026-07-11 ユーザー指示で幅は内容に自動フィット(max-content)。長いデバイス名/詳細行
       (ピル)がはみ出さないよう最長行に合わせて伸び、右ペインの最小幅240pxを侵さないよう
       max-width でクランプする(min-width は以前のJSクランプ下限と同じ180px。ペインが狭い
       ときは flex: 0 1 auto の縮小側で譲る)。以前の #profile-splitter ドラッグによる
       手動幅調整+setState 永続化は自動フィットと両立しないため廃止した。
       高さはデバイス数に応じて自然に伸びる
       (内部スクロールは廃止=ペイン全体の単一スクロールで全デバイスを確認する。ユーザー指定)。 */
    flex: 0 1 auto;
    width: max-content;
    min-width: 180px;
    max-width: calc(100% - 240px);
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
  }
  .machine-device-row {
    padding: 8px 10px;
    border-bottom: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    /* Shift+クリックの範囲選択(2026-07-11)時にブラウザのテキスト範囲選択が同時に走って
       表示が乱れるのを防ぐ。 */
    user-select: none;
  }
  .machine-device-row:last-child { border-bottom: none; }
  /* テーマのアイテムホバー色(list-hoverBackground)そのままでは濃い、というユーザー指摘
     (2026-07-11)により、50%透過に薄めて敷く(color-mix。テーマ変数由来なのでライト/ダーク
     両対応のまま)。device-pick-row のホバー・livePanel の element-row ホバーも同じ式で
     揃えている。選択中の行にホバーしても選択色を上書きしないよう :not(.selected) を付ける。
     カーソルは通常のまま(クリックで選択できるが、ポインタ形状での操作誘導はしない。ユーザー指定)。 */
  .machine-device-row:not(.selected):hover {
    background-color: color-mix(in srgb, var(--vscode-list-hoverBackground) 50%, transparent);
    color: var(--vscode-list-hoverForeground, inherit);
  }
  /* アイテム選択色は拡張内で統一して、プロファイルタブのヘッダーバー(.profile-toolbar)と
     同じ editorGroupHeader-tabsBackground にする(2026-07-11 ユーザー指示。経緯:
     activeSelection の濃い青→inactiveSelection の薄いグレー→ヘッダと同色、の順で確定)。
     「既存のデバイスから選択」のチェック行・ライブ操作パネルの要素行も同じ値。薄い背景
     なので詳細行(.machine-device-detail)の前景色は上書き不要(descriptionForeground の
     ままで読める)。 */
  .machine-device-row.selected {
    background-color: var(--vscode-editorGroupHeader-tabsBackground, rgba(128, 128, 128, 0.15));
  }
  .machine-device-detail {
    margin-top: 4px;
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
  }
  .machine-device-empty {
    /* 一覧が自然高さになったため height:100% は使えない(親が auto 高さだと解決しない)。
       余白で最低限の見た目を確保する。 */
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 12px;
    padding: 32px 12px;
  }
  /* 右ペイン全体のコンテナ(プレースホルダー/編集フォームのどちらか一方だけを表示する)。
     最小幅(240px)は .machine-device-list 側の max-width クランプで確保する。 */
  .machine-device-detail-pane {
    flex: 1 1 auto;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
    /* 一覧と右ペイン内容の間の余白。スプリッター廃止(2026-07-11)で旧サッシ領域の4pxが
       なくなった分を従来の 8px に足し、見た目の間隔を保つ。 */
    padding-left: 12px;
  }
  .profile-detail-placeholder {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    padding: 12px;
  }
  /* 選択中デバイスの編集フォーム(要件2)。フォーム行自体は .modal-row を再利用する。 */
  .machine-device-editor {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 4px 4px 4px 0;
  }
  .machine-device-editor-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 14px;
  }
  /* 編集不可フィールドのラベル表示(テキストボックスではない。ユーザー指定)。
     テキストは選択してコピーできるようにする(user-select: text + cursor: text)。
     編集可の input(高さ約22px)と行の高さを揃え、長い値(UDID等)は省略表示にする
     (DOM には全文があるのでトリプルクリック選択→コピーで全文取得できる)。 */
  .editor-readonly-value {
    flex: 1 1 auto;
    min-width: 0;
    display: block;
    line-height: 22px;
    user-select: text;
    cursor: text;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .editor-platform-label {
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }

  /* ---- プロファイルタブ: アプリプロファイルセクション(中段) ---------------------------- */
  /* 本体は #panel-profiles 側の縦スクロールに乗るため、自身では高さ制約・スクロールを持たず
     内容の自然高さのまま伸びる(実行プロファイルセクションと同じ方針)。「共通」「iOS」
     「Android」の3グループを縦に並べる(グループ見出しは太字。iOS/Android はタイル/レーンの
     デバイス名ピルと同色(.tile-name-ios/-android)のアクセント線を左端に付け、控えめに区別する)。 */
  .app-profile-body {
    padding: 12px;
  }
  .app-profile-editor {
    display: flex;
    flex-direction: column;
  }
  .app-profile-group-title {
    font-weight: 600;
    margin: 14px 0 6px;
  }
  .app-profile-group-title:first-child {
    margin-top: 0;
  }
  .app-profile-group-title-ios {
    border-left: 3px solid #29b6f6;
    padding-left: 6px;
  }
  .app-profile-group-title-android {
    border-left: 3px solid #3ddc84;
    padding-left: 6px;
  }
  /* このフォームも実行プロファイルセクション同様ラベルが長い("自動インストール"等)ため、
     #run-profile-editor と同じ理由で #id で上書きする。 */
  #app-profile-editor .modal-row > label {
    flex: 0 0 170px;
  }

  /* ---- プロファイルタブ: 実行プロファイルセクション(上段) ------------------------------ */
  /* 本体はアプリプロファイルセクションと同様、自身では高さ制約・スクロールを持たず内容の
     自然高さのまま伸びる(#panel-profiles 側の縦スクロールに乗る)。フォームが無い間(0件/
     読み込み失敗)は .profile-detail-placeholder を再利用してプレースホルダー/エラー
     メッセージを表示する。 */
  .run-profile-body {
    padding: 12px;
  }
  .run-profile-editor {
    display: flex;
    flex-direction: column;
  }
  /* 「使用するマシンプロファイル」ラベル横の必須バッジ。 */
  .required-badge {
    display: inline-block;
    margin-left: 6px;
    padding: 1px 5px;
    font-size: 10px;
    border-radius: 3px;
    vertical-align: middle;
    background-color: var(--vscode-inputValidation-errorBackground, rgba(241, 76, 76, 0.15));
    color: var(--vscode-errorForeground, #f14c4c);
  }
  /* このフォームは他の .modal-row 利用箇所(デバイス追加モーダル・デバイス編集フォーム)より
     ラベルが長い(「使用するマシンプロファイル」等)ため、#id で安全に .modal-row > label の
     flex:0 0 90px を上書きする(ソース順に依存しないよう、具体度をID分だけ上げる)。 */
  #run-profile-editor .modal-row > label {
    flex: 0 0 170px;
  }
  /* デバイス一覧は複数行になりうるため、ラベルを上端に揃える。 */
  .run-profile-devices-row {
    align-items: flex-start;
  }
  .run-profile-devices {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .run-profile-device-row {
    display: flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
  }
  .run-profile-device-note {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
  }
  /* マシンプロファイルに存在しないデバイス名のピル(プラットフォーム不明のため中立色。
     .tile-name の白文字が背景無しで見えなくならないようにする)。 */
  .tile-name-unknown {
    background-color: var(--vscode-descriptionForeground, #8a8a8a);
  }
  /* チェックボックス行(heal・自動インストール)は「ラベル+コントロール」の2カラムではなく、
     チェックボックスと文言が横並びの1行なので、.modal-row > label の幅固定指定を打ち消す
     (#run-profile-editor/#app-profile-editor それぞれの170px上書きより後に定義し、こちらは
     .profile-checkbox-row 限定でさらに上書きする。run-profile-heal と app-profile の
     自動インストールで共用するクラス)。 */
  #run-profile-editor .profile-checkbox-row > label,
  #app-profile-editor .profile-checkbox-row > label {
    flex: 1 1 auto;
  }
  /* チェックボックスは VSCode の設定画面(Settings)のチェックボックスと同じ見た目に統一する
     (2026-07-11 ユーザー指示。settings.checkboxBackground/Border/Foreground のテーマ変数を使う)。
     以前のネイティブ描画+accent-color は OS 依存の見た目になるため appearance: none で無効化して
     カスタム描画する。チェックマークは codicon フォントや画像が CSP(外部リソース不可)で
     使えない可能性があるため、::after の回転ボーダー(L字を45度回転)で描く。静的2箇所
     (heal・自動インストール)+動的生成3箇所(実行プロファイルのデバイスチェック一覧・
     デバイス選択ダイアログの iOS/Android 行)すべてに共通で効く。 */
  input[type="checkbox"] {
    -webkit-appearance: none;
    appearance: none;
    width: 18px;
    height: 18px;
    box-sizing: border-box;
    border: 1px solid var(--vscode-settings-checkboxBorder, var(--vscode-widget-border, #919191));
    border-radius: 3px;
    background-color: var(--vscode-settings-checkboxBackground, var(--vscode-input-background));
    position: relative;
    flex: 0 0 auto;
    cursor: pointer;
    vertical-align: middle;
  }
  /* チェックマーク(✓)。::after は content-box のままなので実寸は幅4+右枠2=6px、
     高さ8+下枠2=10px。left/top はこの実寸が18px箱(枠1px)の中で視覚的に中央に
     バランスする位置。 */
  input[type="checkbox"]:checked::after {
    content: '';
    position: absolute;
    left: 5px;
    top: 2px;
    width: 4px;
    height: 8px;
    border: solid var(--vscode-settings-checkboxForeground, var(--vscode-foreground));
    border-width: 0 2px 2px 0;
    transform: rotate(45deg);
  }
  input[type="checkbox"]:focus-visible {
    outline: 1px solid var(--vscode-focusBorder, #007acc);
    outline-offset: 1px;
  }
  input[type="checkbox"]:disabled { opacity: 0.5; cursor: default; }

  /* ---- デバイス追加モーダル ---------------------------------------------------------- */
  input[type="text"] {
    font-family: inherit;
    font-size: inherit;
    padding: 2px 6px;
    border-radius: 2px;
    background-color: var(--vscode-input-background);
    color: var(--vscode-input-foreground);
    border: 1px solid var(--vscode-input-border, var(--vscode-dropdown-border));
  }
  input[type="text"]:disabled { opacity: 0.5; }
  /* 入力済みテキスト(--vscode-input-foreground)とプレースホルダー(ウォーターマーク)がひと目で
     区別できるよう、淡色+イタリックにする(reportDir の "reports" やアプリID欄の
     "bundle id"/"パッケージ名" 等、全 text input のプレースホルダーに共通で効かせる)。 */
  input[type="text"]::placeholder {
    /* 淡色すぎて目立たなかった(ユーザー報告)ため、ライト/ダーク両テーマで「薄い青」に
       見える vscode-charts-blue を使う(イタリックは維持)。 */
    color: var(--vscode-charts-blue, #3794ff);
    opacity: 0.6;
    font-style: italic;
  }
  .modal-overlay {
    position: fixed;
    inset: 0;
    z-index: 2000;
    display: none;
    align-items: center;
    justify-content: center;
    background-color: rgba(0, 0, 0, 0.35);
  }
  .modal-overlay.visible { display: flex; }
  /* #device-pick-overlay のタイトル行にある「+新規作成」ボタンは、そのモーダルを閉じずに
     #device-add-overlay を上に重ねて開く(要件6)。ID セレクタなので .modal-overlay の
     z-index:2000 より詳細度が高く、!important なしで両方 visible のときに手前へ出せる。 */
  #device-add-overlay {
    z-index: 2010;
  }
  /* デバイス追加モーダルは Android のモデル/OSバージョンの選択肢が長く、既定の
     min-width(400px)だと iOS⇄Android 切替のたびにダイアログ幅が伸縮して見た目が暴れる
     (2026-07-11 ユーザー報告)。最小幅を広げて通常の選択肢なら幅が変わらないようにし、
     それでも収まらない長い選択肢のときだけコンテンツに合わせて広がる。max-width で
     ウィンドウ(webview)内には必ず収める(.modal-row > select は min-width: 0 なので
     上限に達したら select 側が縮んで選択肢テキストが省略される)。 */
  #device-add-overlay .modal-dialog {
    min-width: 640px;
    max-width: calc(100vw - 48px);
  }
  .modal-dialog {
    min-width: 400px;
    padding: 16px;
    border-radius: 6px;
    background-color: var(--vscode-editor-background);
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
  }
  .modal-title {
    font-weight: 600;
    margin-bottom: 12px;
  }
  .modal-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 10px;
  }
  /* label・select・input はいずれも直下の要素のみを対象にする(子孫セレクタだと
     .modal-radio-group 内のラジオ用 label/input まで拾ってしまい、幅固定・淡色化や
     flex:1 1 auto によるラジオボタン自体の間延びが意図せず起きるため)。 */
  .modal-row > label {
    flex: 0 0 90px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .modal-row > select,
  .modal-row > input {
    flex: 1 1 auto;
    min-width: 0;
  }
  /* heal チェックボックス(#run-profile-heal)等、.modal-row 直下のチェックボックスは
     上のルールの flex: 1 1 auto が効いて行いっぱいに引き伸ばされてしまう(ユーザー報告)。
     flex を打ち消して左寄せし、margin-right: auto で行の残り幅を右側の余白にする。
     寸法・配色はグローバルの input[type="checkbox"] ルール(VSCode設定画面風のカスタム描画。
     2026-07-11)に任せるため、ここでは width/height/accent-color を持たない。 */
  .modal-row > input[type="checkbox"] {
    flex: 0 0 auto;
    margin: 0;
    margin-right: auto;
  }
  .modal-radio-group {
    flex: 1 1 auto;
    display: flex;
    gap: 16px;
  }
  .modal-radio {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    cursor: pointer;
  }
  /* ラジオはチェックボックス(グローバルの input[type="checkbox"] ルール=VSCode設定画面風の
     カスタム描画)とスタイルを揃える(2026-07-11 ユーザー指示)。同じ寸法(18px)・同じ
     テーマ変数(settings.checkbox 系)で、形だけ円形(border-radius: 50%)にし、チェック
     状態は ::after の中央ドットで描く。appearance: none にするのはチェックボックスと同じ
     理由(OS依存の見た目を避ける)に加え、ネイティブ描画時代に VSCode webview の既定
     スタイル input:focus { outline: 1px solid ...; outline-offset: -1px } がクリックしただけで
     円形ラジオに四角い枠を描いてしまう問題(同日ユーザー報告)があったため。outline: none
     (詳細度21)は既定スタイル(input:focus=11)に常に勝ち、マウスクリックでは枠が出ない。 */
  .modal-radio input[type="radio"] {
    -webkit-appearance: none;
    appearance: none;
    width: 18px;
    height: 18px;
    box-sizing: border-box;
    border: 1px solid var(--vscode-settings-checkboxBorder, var(--vscode-widget-border, #919191));
    border-radius: 50%;
    background-color: var(--vscode-settings-checkboxBackground, var(--vscode-input-background));
    position: relative;
    flex: 0 0 auto;
    cursor: pointer;
    outline: none;
  }
  /* 中央ドット(選択マーク)。18px箱−枠1px=内側16pxの中央に8pxの円(4+8+4)。
     色はチェックボックスのチェックマークと同じ settings.checkboxForeground。 */
  .modal-radio input[type="radio"]:checked::after {
    content: '';
    position: absolute;
    left: 4px;
    top: 4px;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: var(--vscode-settings-checkboxForeground, var(--vscode-foreground));
  }
  /* キーボードフォーカスの可視化はチェックボックス(input[type="checkbox"]:focus-visible)と
     同じ形式で維持する(リングは border-radius: 50% に沿って円形に描かれる)。 */
  .modal-radio input[type="radio"]:focus-visible {
    outline: 1px solid var(--vscode-focusBorder, #007acc);
    outline-offset: 1px;
  }
  /* disabled の淡色化は .modal-radio:has(input:disabled) がラベルごと行うため、ここでは
     カーソルだけ戻す(opacity を重ねると二重に薄くなる)。 */
  .modal-radio input[type="radio"]:disabled { cursor: default; }
  /* OS種別ラジオの選択ドットはプラットフォームの色にする(2026-07-11 ユーザー指示)。
     色はデバイス名ピル(.tile-name-ios / .tile-name-android)と同じ値。 */
  #dlg-platform-ios:checked::after {
    background-color: #29b6f6;
  }
  #dlg-platform-android:checked::after {
    background-color: #3ddc84;
  }
  /* ラジオが disabled の間はラベル文字も含めて淡色化する(select の disabled 見た目に相当)。 */
  .modal-radio:has(input:disabled) {
    opacity: 0.5;
    cursor: default;
  }
  .modal-error {
    min-height: 16px;
    margin-bottom: 8px;
    font-size: 12px;
    color: var(--vscode-errorForeground, #f14c4c);
  }
  /* カタログ読み込み中等の非エラー案内はエラー色ではなく淡色にする。 */
  .modal-error.info {
    color: var(--vscode-descriptionForeground);
  }
  .modal-buttons {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  /* プロファイルタブの3編集フォーム(デバイス/アプリ/実行プロファイル)は、モーダルの
     OK/キャンセルと違いページ内に常駐するボタン行のため、確定ボタンを左寄せにする。
     .modal-buttons 自体はデバイス追加モーダル(右寄せのまま)が使うため変更しない。 */
  .modal-buttons.form-buttons {
    justify-content: flex-start;
  }

  /* ---- 「+既存から選択」モーダル(#device-pick-overlay) ------------------------------------
     実機で iOS シミュレータ62台・Android AVD24個などインストール済みデバイスが大量にある
     前提の設計(コーディネーター指示)。iOS/Android を同時に見比べられるよう左右2カラムに分割し、
     各カラムを独立に固定上限(50vh)でスクロールさせる(従来の一覧全体1本のスクロールは廃止)。
     タイトル・エラー行・OK/キャンセルは常に画面内に収める。2カラムでも名前+詳細が読める幅を
     確保するため、通常の .modal-dialog(400px)よりかなり広い min-width にする(狭い画面では
     max-width で画面内に収める)。 */
  #device-pick-overlay .modal-dialog {
    min-width: 640px;
    max-width: calc(100vw - 48px);
  }
  .device-pick-list {
    display: flex;
    gap: 12px;
    margin-bottom: 8px;
  }
  /* グループ=見出し+スクロール本体の縦flex。スクロールは本体(.device-pick-group-body)だけに
     持たせ、見出しはスクロール領域の外で常に固定表示にする(2026-07-11 ユーザー指示)。
     以前は カラム全体をスクロールコンテナにして見出しを position: sticky にしていたが、
     行のチェックボックスがカスタム描画で position: relative(=位置指定要素)のため、
     z-index の無い sticky 見出しより上に描画されてしまい、スクロールすると見出しに
     チェックボックスが被る問題があった。 */
  .device-pick-group {
    flex: 1 1 0;
    min-width: 0;
    max-height: 50vh;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 4px;
    display: flex;
    flex-direction: column;
  }
  /* グループ見出しに件数を出す(「iOS シミュレータ (62)」のように、探しやすくするための要件)。
     件数は JS 側で textContent に埋め込む(このセレクタ自体は見た目のみを担う)。 */
  .device-pick-group-title {
    flex: none;
    padding: 6px 10px;
    font-size: 12px;
    font-weight: 600;
    color: var(--vscode-descriptionForeground);
  }
  .device-pick-group-body {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
  }
  .device-pick-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
  }
  /* 選択中(登録される)行にホバーしても選択色を上書きしないよう :not(.checked) を付ける
     (.machine-device-row の :not(.selected):hover と同じ方針)。ホバー色を50%透過に薄める
     理由も .machine-device-row 側のコメント参照(2026-07-11 ユーザー指摘)。 */
  .device-pick-row:not(.checked):hover {
    background-color: color-mix(in srgb, var(--vscode-list-hoverBackground) 50%, transparent);
  }
  /* チェックON=登録される行に背景を敷き、チェックボックス以外でも選択状態が一目で分かる
     ようにする(2026-07-11 ユーザー指示)。色は薄いグレーの非フォーカス選択色
     (inactiveSelectionBackground)。一時、他の選択色と同じヘッダー色
     (editorGroupHeader-tabsBackground)に統一したが、このモーダルだけは元に戻す指示があった
     (同日)=マシンプロファイルのデバイス行・ライブ操作パネルの選択色とは意図的に別の値。
     前景色は上書きしない(薄い背景なら詳細行の descriptionForeground のままで読める)。 */
  .device-pick-row.checked {
    background-color: var(--vscode-list-inactiveSelectionBackground, rgba(128, 128, 128, 0.18));
  }
  /* 寸法・配色はグローバルの input[type="checkbox"] ルール(VSCode設定画面風のカスタム描画。
     2026-07-11)に任せる。UA既定margin だけ打ち消し、行内の間隔は .device-pick-row の
     gap: 8px で確保する。 */
  .device-pick-row input[type="checkbox"] {
    margin: 0;
  }
  .device-pick-row-text {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  /* デバイス名は他画面(タイル/レーン/マシンプロファイル一覧)と同じ配色ピル(.tile-name /
     .tile-name-ios / .tile-name-android)を共用する(要件2。色分けで統一感を出す)。
     縦積み(flex-direction: column)の中では align-items の既定 stretch でピルが行幅いっぱいに
     伸びてしまうため、align-self: flex-start でテキスト幅にフィットさせる。 */
  .device-pick-row-name {
    align-self: flex-start;
    max-width: 100%;
  }
  .device-pick-row-detail {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .device-pick-empty {
    padding: 10px;
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  /* タイトル文字列+右端の「+」新規作成ボタン(#device-pick-add-new)を横並びにする行。
     .modal-title のマージンはそのまま流用しつつ、ボタンを右端へ寄せる。 */
  .device-pick-title-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  /* チェックを外すと登録解除される旨の常設注記(要件5)。誤操作への注意喚起だが、常時
     目に入ると煩わしいため小さく・淡色にする(.modal-error より優先度が低い情報のため)。 */
  .device-pick-note {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
    opacity: 0.8;
    margin-bottom: 8px;
  }
</style>
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
      <span id="status" class="status">接続中...</span>
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

  <script nonce="${nonce}">
  (function () {
    const vscode = acquireVsCodeApi();

    const OVERALL_LANE_ID = ${JSON.stringify(OVERALL_LANE_ID)};
    const OVERALL_LANE_NAME = ${JSON.stringify(OVERALL_LANE_NAME)};
    const MAX_LANE_LINES = ${JSON.stringify(MAX_LANE_LINES)};

    const toolbar = document.getElementById('toolbar');
    const grid = document.getElementById('grid');
    const emptyMessage = document.getElementById('empty');
    const banner = document.getElementById('banner');
    const statusEl = document.getElementById('status');
    const btnUp = document.getElementById('btn-devices-up');
    const btnDown = document.getElementById('btn-devices-down');
    const btnRestart = document.getElementById('btn-restart');
    const profileSelect = document.getElementById('profile-select');

    const devicesPanel = document.getElementById('panel-devices');
    const tilePane = document.getElementById('tile-pane');
    const splitter = document.getElementById('splitter');
    const lanesPlaceholder = document.getElementById('lanes-placeholder');
    const lanesGrid = document.getElementById('lanes-grid');
    const lanesSelectionStatus = document.getElementById('lanes-selection-status');
    const lanesRunStatus = document.getElementById('lanes-run-status');

    const deviceOpMenu = document.getElementById('device-op-menu');
    const deviceOpMenuItemBtn = document.getElementById('device-op-menu-item');

    const STATE_LABEL = {
      connected: '接続済み',
      booted: '起動中',
      offline: '未起動',
    };

    // 複製元: src/monitorModel.ts の deviceOpMenuItem。webview は CSP により import 不可のため
    // 複製する(healReviewPanel.ts が healModel.ts の一部ロジックを複製しているのと同じ方針)。
    // タイル右クリックメニューの項目ラベル・実行する操作と、実行中/待機中バッジの表示にも共用する。
    // busy は { op, status } の形('queued'=順番待ち／'running'=実行中)。無ければ undefined。
    function deviceOpMenuItem(state, busy) {
      if (busy && busy.status === 'queued') { return { label: '待機中...', op: busy.op, disabled: true }; }
      if (busy && busy.op === 'up') { return { label: '起動中...', op: 'up', disabled: true }; }
      if (busy && busy.op === 'down') { return { label: '停止中...', op: 'down', disabled: true }; }
      return state === 'offline'
        ? { label: '起動', op: 'up', disabled: false }
        : { label: '停止', op: 'down', disabled: false };
    }

    // device id -> タイルの DOM 要素・最新フレーム(1枚のみ保持。履歴は溜めない)
    const tiles = new Map();
    // レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
    const lanes = new Map();
    // タイルクリックで選択された device id 集合(空 = 全ワーカー表示)
    const selectedDeviceIds = new Set();

    function formatTime(date) {
      const pad = (n) => String(n).padStart(2, '0');
      return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    }

    // ---- 上下ペインのスプリッター ---------------------------------------------
    // タイルペイン(上)の高さを JS 側の状態として保持し、setState/getState にも保存して
    // パネル再表示時に復元する。出力ペイン(下)は flex の残りスペースを自動的に占有するので、
    // 高さを個別に管理する必要はない。

    const MIN_PANE_HEIGHT = 120;
    const persistedState = vscode.getState() || {};
    let tilePaneHeight =
      typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
        ? persistedState.tilePaneHeight
        : Math.round(window.innerHeight * 0.45);

    // タイルペイン+出力ペインに配分できる合計の高さ(ツールバー・バナー・スプリッター分を除く)。
    // タブ導入前は document.body.clientHeight を基準にしていたが、タブバー分の高さがずれるため、
    // 「デバイス」タブのパネル(既存要素一式を包むコンテナ)自身の clientHeight を基準にする。
    function availableSplitHeight() {
      const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
      return devicesPanel.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
    }

    // 上下それぞれ最小 MIN_PANE_HEIGHT を確保するようにクランプする。
    function clampTilePaneHeight(height) {
      const available = availableSplitHeight();
      const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
      return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
    }

    function applyTilePaneHeight(height) {
      // 「デバイス」タブが非表示(display:none)の間は devicesPanel.clientHeight が 0 になり、
      // clampTilePaneHeight が誤って最小値 120px に丸めてしまう。何もせず抜け、タブが
      // 「デバイス」に戻った直後(switchTab)に呼び直して再クランプする。
      if (devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null) {
        return;
      }
      tilePaneHeight = clampTilePaneHeight(height);
      tilePane.style.height = tilePaneHeight + 'px';
      relayoutTiles();
    }

    function persistTilePaneHeight() {
      vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight }));
    }

    applyTilePaneHeight(tilePaneHeight);
    // ウィンドウリサイズ/バナー表示切替でも上下の最小高さを維持する。
    window.addEventListener('resize', () => applyTilePaneHeight(tilePaneHeight));

    let splitterPointerId = null;
    let splitterStartY = 0;
    let splitterStartHeight = 0;

    splitter.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) {
        return;
      }
      splitterPointerId = event.pointerId;
      splitterStartY = event.clientY;
      splitterStartHeight = tilePaneHeight;
      splitter.setPointerCapture(event.pointerId);
      splitter.classList.add('dragging');
      event.preventDefault();
    });
    splitter.addEventListener('pointermove', (event) => {
      if (splitterPointerId !== event.pointerId) {
        return;
      }
      applyTilePaneHeight(splitterStartHeight + (event.clientY - splitterStartY));
    });
    const endSplitterDrag = (event) => {
      if (splitterPointerId !== event.pointerId) {
        return;
      }
      splitterPointerId = null;
      splitter.classList.remove('dragging');
      splitter.releasePointerCapture(event.pointerId);
      persistTilePaneHeight();
    };
    splitter.addEventListener('pointerup', endSplitterDrag);
    splitter.addEventListener('pointercancel', endSplitterDrag);

    // ---- デバイスタイル -----------------------------------------------------

    // タイル内の「画像以外」の高さの合計(px)。CSS の固定高と一致させること:
    // padding 上下 8+8 + header 20 + footer 18 + gap 6×2 = 66
    const TILE_CHROME_HEIGHT = 66;

    // タイルの実測高さ(グリッドの stretch 結果)から画像に使える高さを算出し、
    // CSS 変数 --tile-image-h として grid に設定する(タイル幅はこの高さ×アスペクト比で決まる)。
    // スプリッター移動・リサイズ・タイル生成のたびに呼ぶ。
    function relayoutTiles() {
      const probe = grid.querySelector('.tile');
      if (!probe) {
        return;
      }
      const imageHeight = Math.max(60, probe.clientHeight - TILE_CHROME_HEIGHT);
      grid.style.setProperty('--tile-image-h', imageHeight + 'px');
    }

    function createTile(device) {
      const tile = document.createElement('div');
      tile.className = 'tile';
      // ボタン廃止(要件1)によりヒントが無くなるため、ツールチップで操作方法を示す
      // (macOS GUI 版のタイルの .help() と同じ趣旨)。
      tile.title = 'クリックで選択 / 右クリックで起動・停止';
      tile.addEventListener('click', () => toggleDeviceSelection(device.id));
      tile.addEventListener('contextmenu', (event) => {
        // 既定の(OS/ブラウザの)コンテキストメニューを抑止し、タイル本体のクリック
        // (レーン絞り込みの選択トグル)にも波及させない。
        event.preventDefault();
        event.stopPropagation();
        openDeviceOpMenu(entry, event.clientX, event.clientY);
      });

      // ヘッダー: 左からプラットフォーム色で装飾したデバイス名、右端に「実行中」
      // (個別起動/停止は右クリックメニューに移動した。ボタンが無くなった分、名前表示が
      // フル幅を使える)
      const header = document.createElement('div');
      header.className = 'tile-header';
      const name = document.createElement('span');
      name.className = 'tile-name';
      const runningBadge = document.createElement('span');
      runningBadge.className = 'badge badge-running';
      runningBadge.textContent = '実行中';
      header.append(name, runningBadge);

      const frameWrap = document.createElement('div');
      frameWrap.className = 'frame-wrap';
      const img = document.createElement('img');
      const placeholder = document.createElement('div');
      placeholder.className = 'frame-placeholder';
      // 起動/停止操作中バッジ(画像左上に重ねる。要件3)。renderFrame() が
      // frame-wrap の中身を作り直すたびに末尾へ再アペンドする。
      const opBadge = document.createElement('span');
      opBadge.className = 'tile-op-badge';

      // フッター: [状態テキスト] [⚠エラー(あれば、中間で省略)] [HH:MM:SS(右寄せ)]
      const footer = document.createElement('div');
      footer.className = 'tile-footer';
      const stateBadge = document.createElement('span');
      stateBadge.className = 'tile-state';
      const updated = document.createElement('span');
      updated.className = 'tile-updated';
      const error = document.createElement('span');
      error.className = 'tile-error';
      footer.append(stateBadge, error, updated);

      tile.append(header, frameWrap, footer);
      grid.appendChild(tile);

      const entry = {
        device,
        tile,
        nameEl: name,
        // そのデバイスの直列キュー上の状態({ op: 'up'|'down', status: 'queued'|'running' })。
        // キューに入っていなければ undefined。
        opBusy: undefined,
        opBadgeEl: opBadge,
        stateBadgeEl: stateBadge,
        runningBadgeEl: runningBadge,
        frameWrapEl: frameWrap,
        imgEl: img,
        placeholderEl: placeholder,
        updatedEl: updated,
        errorEl: error,
        frameSrc: null,
        lastUpdated: null,
      };
      tiles.set(device.id, entry);
      return entry;
    }

    function renderFrame(entry) {
      entry.frameWrapEl.textContent = '';
      if (entry.device.state !== 'offline' && entry.frameSrc) {
        entry.imgEl.src = entry.frameSrc;
        entry.imgEl.alt = entry.device.name;
        entry.frameWrapEl.appendChild(entry.imgEl);
      } else {
        // フレーム未受信のプレースホルダーはデバイス状態で出し分ける
        // (offline=未起動+電源アイコン / それ以外(booted・接続直後でフレーム未着)=起動中+スピナー)
        const offline = entry.device.state === 'offline';
        entry.placeholderEl.textContent = '';
        const icon = document.createElement('span');
        if (offline) {
          icon.className = 'placeholder-icon offline';
          icon.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"'
            + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round">'
            + '<path d="M8 1.8v5.4"/><path d="M4.4 3.9a5.4 5.4 0 1 0 7.2 0"/></svg>';
        } else {
          icon.className = 'placeholder-icon booting';
        }
        const labelSpan = document.createElement('span');
        labelSpan.textContent = offline ? '未起動' : '起動中';
        entry.placeholderEl.append(icon, labelSpan);
        entry.frameWrapEl.appendChild(entry.placeholderEl);
      }
      entry.frameWrapEl.appendChild(entry.opBadgeEl);
    }

    function renderMeta(entry) {
      entry.nameEl.textContent = entry.device.name;
      entry.nameEl.className = 'tile-name tile-name-' + entry.device.platform;
      entry.nameEl.title = entry.device.name + ' (' + entry.device.platform + ')';
      // フッター左下の表示ルール:
      //   connected(フレーム表示中) → 「接続済み」
      //   booted(iOSブリッジ未接続 / Androidブート完了待ち) → 「接続中」
      //   それ以外(未起動・フレーム未着) → 空(要素は固定高レイアウトのため残す)
      let footerText = '';
      if (entry.device.state === 'connected' && entry.frameSrc) {
        footerText = STATE_LABEL.connected;
      } else if (entry.device.state === 'booted') {
        footerText = '接続中';
      }
      entry.stateBadgeEl.textContent = footerText;
      entry.updatedEl.textContent = entry.lastUpdated ? formatTime(entry.lastUpdated) : '';
      renderOpBadge(entry);
      // 右クリックメニューがこのタイルに対して開いていれば、内容(ラベル/disabled)も
      // 最新の state/opBusy で更新する。
      if (deviceOpMenuEntry === entry) {
        renderDeviceOpMenuItem();
      }
    }

    // 起動/停止操作中バッジの表示可否・文言を、デバイスの現在状態(state)とそのデバイスで
    // 実行中の操作(opBusy)から再計算する。devices サイクル毎(renderMeta 経由)と
    // deviceOpBusy 受信時の両方から呼ぶ(モニターの既存ポーリングで状態変化が反映される)。
    function renderOpBadge(entry) {
      const item = deviceOpMenuItem(entry.device.state, entry.opBusy);
      entry.opBadgeEl.textContent = item.label;
      entry.opBadgeEl.classList.toggle('visible', item.disabled);
    }

    // ---- タイル右クリックメニュー ---------------------------------------------

    // 現在メニューを開いている対象のタイル entry(未オープンなら null)。
    let deviceOpMenuEntry = null;

    function renderDeviceOpMenuItem() {
      if (!deviceOpMenuEntry) {
        return;
      }
      const item = deviceOpMenuItem(deviceOpMenuEntry.device.state, deviceOpMenuEntry.opBusy);
      deviceOpMenuItemBtn.textContent = item.label;
      deviceOpMenuItemBtn.disabled = item.disabled;
      deviceOpMenuItemBtn.dataset.op = item.op;
    }

    function closeDeviceOpMenu() {
      if (!deviceOpMenuEntry) {
        return;
      }
      deviceOpMenuEntry = null;
      deviceOpMenu.classList.remove('visible');
    }

    // 自作の右クリックメニュー(fixed div)をマウス位置に開く際、画面端でははみ出さないよう
    // 実測サイズで座標をクランプする。タイル右クリックメニュー・プロファイルタブのデバイス行
    // 右クリックメニュー(machine-device-menu)で共用する。
    function clampMenuPosition(menuEl, clientX, clientY) {
      const rect = menuEl.getBoundingClientRect();
      const maxX = Math.max(4, window.innerWidth - rect.width - 4);
      const maxY = Math.max(4, window.innerHeight - rect.height - 4);
      menuEl.style.left = Math.min(Math.max(clientX, 4), maxX) + 'px';
      menuEl.style.top = Math.min(Math.max(clientY, 4), maxY) + 'px';
    }

    // マウス位置にメニューを開く。
    function openDeviceOpMenu(entry, clientX, clientY) {
      deviceOpMenuEntry = entry;
      renderDeviceOpMenuItem();
      deviceOpMenu.classList.add('visible');
      clampMenuPosition(deviceOpMenu, clientX, clientY);
    }

    deviceOpMenuItemBtn.addEventListener('click', (event) => {
      event.stopPropagation();
      if (!deviceOpMenuEntry || deviceOpMenuItemBtn.disabled) {
        return;
      }
      vscode.postMessage({
        type: 'deviceOp',
        name: deviceOpMenuEntry.device.name,
        op: deviceOpMenuItemBtn.dataset.op,
      });
      closeDeviceOpMenu();
    });

    // メニュー外クリック・Esc・スクロールで閉じる(要件2)。
    document.addEventListener('click', (event) => {
      if (deviceOpMenuEntry && !deviceOpMenu.contains(event.target)) {
        closeDeviceOpMenu();
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeDeviceOpMenu();
      }
    });
    // capture:true で登録することで、スクロール可能な子要素(grid の横スクロール・
    // lane-body 等)で発生した(バブリングしない)scroll イベントも document 側で拾える。
    document.addEventListener('scroll', () => closeDeviceOpMenu(), true);
    window.addEventListener('resize', () => closeDeviceOpMenu());
    // タイル上での contextmenu は stopPropagation 済みなのでここには来ない。
    // タイル外(空きエリア等)で右クリックし、既定のコンテキストメニューが別途開く場合に
    // こちらのメニューを残さないようにする。
    document.addEventListener('contextmenu', () => closeDeviceOpMenu());

    // デバイス名から対応するタイルを探す(deviceOp は --name(論理名)だけを host に渡すため、
    // host からの deviceOpBusy/deviceOpFailed 応答も name で返ってくる)。
    function findTileByName(name) {
      for (const entry of tiles.values()) {
        if (entry.device.name === name) {
          return entry;
        }
      }
      return undefined;
    }

    function touch(entry) {
      entry.lastUpdated = new Date();
      renderMeta(entry);
    }

    // monitorError はタイルに表示したままにせず、そのデバイスの monitorFrame か state 更新
    // (devices サイクル)を受信した時点で消す(過渡的なエラーが赤字のまま残り続けないように)。
    function setTileError(entry, message) {
      entry.errorEl.textContent = '⚠ ' + message;
      entry.errorEl.title = message;
    }

    function clearTileError(entry) {
      entry.errorEl.textContent = '';
      entry.errorEl.removeAttribute('title');
    }

    function applyDevices(devices) {
      const seen = new Set();
      for (const device of devices) {
        seen.add(device.id);
        let entry = tiles.get(device.id);
        if (!entry) {
          entry = createTile(device);
          entry.runningBadgeEl.style.display = runningWorkers.has(device.id) ? 'inline-block' : 'none';
        } else {
          entry.device = device;
        }
        touch(entry);
        renderFrame(entry);
        clearTileError(entry);
      }
      for (const [id, entry] of tiles) {
        if (!seen.has(id)) {
          if (deviceOpMenuEntry === entry) {
            closeDeviceOpMenu();
          }
          entry.tile.remove();
          tiles.delete(id);
          selectedDeviceIds.delete(id);
        }
      }
      emptyMessage.style.display = tiles.size === 0 ? 'flex' : 'none';
      relayoutTiles();
      syncLanesToDevices(devices);
      updateLaneVisibility();
    }

    function applyFrame(message) {
      const entry = tiles.get(message.device);
      if (!entry) {
        return; // devices サイクルより先に届いた場合は無視する(次の devices で改めて反映される)
      }
      entry.frameSrc = 'data:image/jpeg;base64,' + message.jpegBase64;
      // 実フレームのアスペクト比でタイル幅を決める(縦横比の異なるデバイスが混在しても
      // それぞれの画像幅ちょうどに締まる)
      if (message.width > 0 && message.height > 0) {
        entry.tile.style.setProperty('--tile-aspect', (message.width / message.height).toFixed(4));
      }
      touch(entry);
      renderFrame(entry);
      clearTileError(entry);
    }

    function applyDeviceError(message) {
      const entry = message.device ? tiles.get(message.device) : undefined;
      if (entry) {
        setTileError(entry, message.message);
        return;
      }
      showBanner(message.message);
    }

    function showBanner(text) {
      banner.textContent = text;
      banner.classList.add('visible');
    }
    function hideBanner() {
      banner.textContent = '';
      banner.classList.remove('visible');
    }

    function setBusy(busy) {
      btnUp.disabled = busy;
      btnDown.disabled = busy;
      statusEl.textContent = busy ? '操作を実行中...' : 'モニタリング中';
    }

    // ---- 実行プロファイル選択 ---------------------------------------------------
    // 追加/コピー/削除/名前変更はプロファイルタブ下半分の実行プロファイルセクションに移設した
    // (btn-run-profile-*)。ここでは「使用する実行プロファイルを指定するだけ」の select のみを扱う。

    const PROFILE_NONE_LABEL = '(プロファイルなし)';

    // profileInfo 受信のたびに select の中身を作り直す(現在値が profiles に無い場合も、
    // 設定に手書きされた未知の名前として option を補い選択状態を保つ)。
    function applyProfileInfo(message) {
      const profiles = Array.isArray(message.profiles) ? message.profiles : [];
      const current = typeof message.current === 'string' ? message.current : '';
      profileSelect.textContent = '';

      const noneOption = document.createElement('option');
      noneOption.value = '';
      noneOption.textContent = PROFILE_NONE_LABEL;
      profileSelect.appendChild(noneOption);

      let matched = current === '';
      for (const name of profiles) {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        profileSelect.appendChild(option);
        if (name === current) {
          matched = true;
        }
      }
      if (!matched) {
        const unknownOption = document.createElement('option');
        unknownOption.value = current;
        unknownOption.textContent = current;
        profileSelect.appendChild(unknownOption);
      }
      profileSelect.value = current;
      profileSelect.disabled = false;
    }

    profileSelect.addEventListener('change', () => {
      vscode.postMessage({ type: 'selectProfile', profile: profileSelect.value });
    });

    function toggleDeviceSelection(id) {
      if (selectedDeviceIds.has(id)) {
        selectedDeviceIds.delete(id);
      } else {
        selectedDeviceIds.add(id);
      }
      updateSelectionUi();
    }

    function updateSelectionUi() {
      for (const [id, entry] of tiles) {
        entry.tile.classList.toggle('selected', selectedDeviceIds.has(id));
      }
      updateLaneVisibility();
    }

    // 空きエリア(タイルの外、横スクロールコンテナ内の余白を含む)をクリックしたら選択を全解除する。
    grid.addEventListener('click', (event) => {
      if (event.target === grid && selectedDeviceIds.size > 0) {
        selectedDeviceIds.clear();
        updateSelectionUi();
      }
    });

    // ホイール操作を横スクロールに変換する(下回転→右スクロール、上回転→左スクロール)。
    // トラックパッドの横方向(deltaX)はそのまま加算し、縦回転(deltaY)も横スクロールに合算する。
    // ページ側の縦スクロールに奪われないよう preventDefault() するため passive:false で登録する。
    grid.addEventListener(
      'wheel',
      (event) => {
        grid.scrollLeft += event.deltaX + event.deltaY;
        event.preventDefault();
      },
      { passive: false },
    );

    // 中ボタン(ホイールボタン)ドラッグでパンスクロール(GUI版のステップ表と同じ操作感)。
    // 「掴んで動かす」向き = ポインタを右へ動かすとコンテンツが右へ付いてくる(scrollLeft は減る)。
    // Pointer Events + setPointerCapture でグリッド外へ出てもドラッグを継続する。
    let panPointerId = null;
    let panLastX = 0;
    grid.addEventListener('pointerdown', (event) => {
      if (event.button !== 1) {
        return;
      }
      panPointerId = event.pointerId;
      panLastX = event.clientX;
      grid.setPointerCapture(event.pointerId);
      grid.style.cursor = 'grabbing';
      event.preventDefault();
    });
    grid.addEventListener('pointermove', (event) => {
      if (panPointerId !== event.pointerId) {
        return;
      }
      grid.scrollLeft -= event.clientX - panLastX;
      panLastX = event.clientX;
    });
    const endPan = (event) => {
      if (panPointerId !== event.pointerId) {
        return;
      }
      panPointerId = null;
      grid.style.cursor = '';
      grid.releasePointerCapture(event.pointerId);
    };
    grid.addEventListener('pointerup', endPan);
    grid.addEventListener('pointercancel', endPan);
    // Chromium の中クリック既定動作(オートスクロール等)を抑止する
    grid.addEventListener('auxclick', (event) => {
      if (event.button === 1) {
        event.preventDefault();
      }
    });

    // ---- ログレーン -----------------------------------------------------------

    // worker id(またはタイルが存在しない全体レーン)ごとの「実行中」状態。
    const runningWorkers = new Set();

    function setTileRunning(id, running) {
      if (running) {
        runningWorkers.add(id);
      } else {
        runningWorkers.delete(id);
      }
      const entry = tiles.get(id);
      if (entry) {
        entry.runningBadgeEl.style.display = running ? 'inline-block' : 'none';
      }
    }

    // レーン名はデバイスタイルのタイトルと同じテキスト・同じ装飾(色付きピル)にする。
    // platform 不明(全体レーンやフォールバック)は中立色のピル。
    function setLaneHeader(headerEl, name, platform) {
      headerEl.textContent = '';
      const pill = document.createElement('span');
      pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
      pill.textContent = name;
      headerEl.appendChild(pill);
    }

    // updateLabel=true は workersReady/hydrate/デバイス同期によるレーン構成時のみ。
    // 行追加(appendLaneLine)からの呼び出しで true にすると、フォールバック名(生の worker id)で
    // 構成済みの表示名を上書きしてしまう(過去に実際に起きた表記崩れ)。
    function ensureLane(id, name, platform, updateLabel) {
      let lane = lanes.get(id);
      if (lane) {
        if (updateLabel) {
          setLaneHeader(lane.headerEl, name, platform);
        }
        return lane;
      }
      const el = document.createElement('div');
      el.className = 'lane';
      const header = document.createElement('div');
      header.className = 'lane-header';
      setLaneHeader(header, name, platform);
      const body = document.createElement('div');
      body.className = 'lane-body';
      el.append(header, body);
      lanesGrid.appendChild(el);

      lane = { el, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
      body.addEventListener('scroll', () => {
        lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
      });
      lanes.set(id, lane);
      updateLaneVisibility();
      return lane;
    }

    function appendLaneLine(laneId, text) {
      const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? OVERALL_LANE_NAME : laneId, undefined, false);
      const wasAtBottom = lane.atBottom;
      const line = document.createElement('div');
      line.className = 'lane-line';
      line.textContent = text;
      lane.bodyEl.appendChild(line);
      lane.lineCount += 1;
      while (lane.lineCount > MAX_LANE_LINES) {
        const first = lane.bodyEl.firstChild;
        if (!first) {
          break;
        }
        lane.bodyEl.removeChild(first);
        lane.lineCount -= 1;
      }
      if (wasAtBottom) {
        lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
      }
    }

    function clearAllLanes() {
      for (const lane of lanes.values()) {
        lane.el.remove();
      }
      lanes.clear();
      for (const id of [...runningWorkers]) {
        setTileRunning(id, false);
      }
      lanesRunStatus.textContent = '';
      updateLaneVisibility();
    }

    function configureLanes(laneInfos) {
      const nextIds = new Set(laneInfos.map((l) => l.id));
      for (const [id, lane] of [...lanes]) {
        if (!nextIds.has(id)) {
          lane.el.remove();
          lanes.delete(id);
        }
      }
      for (const info of laneInfos) {
        ensureLane(info.id, info.name, info.platform, true);
      }
      updateLaneVisibility();
    }

    function updateLaneVisibility() {
      const allIds = [...lanes.keys()];
      const activeIds = selectedDeviceIds.size > 0
        ? allIds.filter((id) => selectedDeviceIds.has(id))
        : allIds;
      const columns = Math.max(1, activeIds.length);
      lanesGrid.style.gridTemplateColumns = 'repeat(' + columns + ', minmax(0, 1fr))';
      for (const [id, lane] of lanes) {
        lane.el.style.display = activeIds.includes(id) ? 'flex' : 'none';
      }
      lanesSelectionStatus.textContent = selectedDeviceIds.size > 0
        ? '選択中' + selectedDeviceIds.size + '台を表示'
        : '全ワーカー';
    }

    // 出力ペインは常設で、実行前でもデバイス毎の空レーンを表示する(ユーザー指定で
    // プレースホルダー文言は廃止)。レーンはモニターの devices サイクルから常時同期する。
    function updateLanesPlaceholder() {
      lanesPlaceholder.style.display = 'none';
      lanesGrid.style.display = 'grid';
    }
    updateLanesPlaceholder();

    // モニターのデバイス一覧に合わせて空レーンを用意する(既存レーンはそのまま。
    // 実行開始(cleared)で一旦消えても、次の devices サイクル(interval秒毎)で復元される)。
    function syncLanesToDevices(devices) {
      for (const device of devices) {
        ensureLane(device.id, device.name, device.platform, true);
      }
    }

    function applyLaneAction(action) {
      switch (action.type) {
        case 'cleared':
          clearAllLanes();
          break;
        case 'lanesConfigured':
          configureLanes(action.lanes);
          break;
        case 'line':
          appendLaneLine(action.laneId, action.text);
          break;
        case 'workerRunning':
          setTileRunning(action.workerId, action.running);
          break;
        case 'runFinished':
          lanesRunStatus.textContent = '完了: 成功 ' + action.passed + ' / 失敗 ' + action.failed;
          break;
        default:
          break;
      }
    }

    function applyLaneHydrate(snapshot) {
      clearAllLanes();
      if (snapshot.lanes.length > 0) {
        configureLanes(snapshot.lanes);
      }
      for (const laneId of Object.keys(snapshot.linesByLane)) {
        for (const text of snapshot.linesByLane[laneId]) {
          appendLaneLine(laneId, text);
        }
      }
      for (const workerId of snapshot.runningWorkers) {
        setTileRunning(workerId, true);
      }
    }

    // ---- メッセージ受信 ---------------------------------------------------------

    window.addEventListener('message', (event) => {
      const message = event.data;
      if (!message || typeof message.type !== 'string') {
        return;
      }
      switch (message.type) {
        case 'devices':
          hideBanner();
          statusEl.textContent = 'モニタリング中';
          applyDevices(message.devices);
          break;
        case 'frame':
          applyFrame(message);
          break;
        case 'deviceError':
          applyDeviceError(message);
          break;
        case 'bootBusy':
          setBusy(!!message.busy);
          break;
        case 'processDown':
          statusEl.textContent = '停止中';
          showBanner(message.message);
          break;
        case 'deviceOpBusy': {
          const entry = findTileByName(message.name);
          if (entry) {
            entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
            renderOpBadge(entry);
            if (deviceOpMenuEntry === entry) {
              renderDeviceOpMenuItem();
            }
          }
          break;
        }
        case 'deviceOpFailed':
          showBanner(message.name + ': ' + message.message);
          break;
        case 'laneSectionVisible':
          // レーンは常時表示になったため何もしない(TS側からのメッセージ自体は互換のため残る)
          break;
        case 'runEvent':
          applyLaneAction(message.action);
          break;
        case 'laneHydrate':
          applyLaneHydrate(message.snapshot);
          break;
        case 'profileInfo':
          applyProfileInfo(message);
          applyAppProfileInfo(message);
          applyRunProfileInfo(message);
          break;
        case 'machineProfileInfo':
          applyMachineProfileInfo(message);
          rerenderRunProfileFormIfClean();
          break;
        case 'machineProfileSelected':
          applyMachineProfileSelected(message);
          break;
        case 'deviceCatalog':
          applyDeviceCatalog(message);
          break;
        case 'createDeviceResult':
          applyCreateDeviceResult(message);
          break;
        case 'installedDevices':
          applyInstalledDevices(message);
          break;
        case 'machineDevicesSyncResult':
          applyMachineDevicesSyncResult(message);
          break;
        case 'machineDeviceUpdateResult':
          applyMachineDeviceUpdateResult(message);
          break;
        case 'runProfileSelected':
          applyRunProfileSelected(message);
          break;
        case 'runProfileData':
          applyRunProfileData(message);
          break;
        case 'runProfileSaveResult':
          applyRunProfileSaveResult(message);
          break;
        case 'runProfileFileChanged':
          applyRunProfileFileChanged(message);
          break;
        case 'appProfileSelected':
          applyAppProfileSelected(message);
          break;
        case 'appProfileData':
          applyAppProfileData(message);
          break;
        case 'appProfileSaveResult':
          applyAppProfileSaveResult(message);
          break;
        case 'appProfileFileChanged':
          applyAppProfileFileChanged(message);
          break;
        case 'nameInputOpen':
          applyNameInputOpen(message);
          break;
        default:
          break;
      }
    });

    btnUp.addEventListener('click', () => vscode.postMessage({ type: 'devicesUp' }));
    btnDown.addEventListener('click', () => vscode.postMessage({ type: 'devicesDown' }));
    btnRestart.addEventListener('click', () => {
      hideBanner();
      statusEl.textContent = '再起動中...';
      closeDeviceOpMenu();
      for (const entry of tiles.values()) {
        entry.tile.remove();
      }
      tiles.clear();
      selectedDeviceIds.clear();
      emptyMessage.style.display = 'flex';
      vscode.postMessage({ type: 'restartMonitor' });
    });

    // ---- プロファイルタブ: マシンプロファイル ---------------------------------------
    // machines/*.json の内容(machineProfileInfo)を一覧表示し、「+新規作成」/「+既存から選択」
    // からそれぞれのデバイス追加モーダルを開く。ホストとの往復が要るのは
    // deviceCatalogRequest/createDevice/installedDevicesRequest/machineDevicesSync/
    // machineDeviceRemove のみで、マシン選択(select の change)自体は受信済みデータの
    // 再描画だけで完結する。

    const machineSelect = document.getElementById('machine-select');
    const machineNameStatic = document.getElementById('machine-name-static');
    const btnMachineAdd = document.getElementById('btn-machine-add');
    const btnMachineCopy = document.getElementById('btn-machine-copy');
    const btnMachineRemove = document.getElementById('btn-machine-remove');
    const btnMachineRename = document.getElementById('btn-machine-rename');
    const btnDeviceAddExisting = document.getElementById('btn-device-add-existing');
    const machineProfileError = document.getElementById('machine-profile-error');
    const machineProfileBody = document.getElementById('machine-profile-body');
    const machineDeviceList = document.getElementById('machine-device-list');
    const profileDetailPlaceholder = document.getElementById('profile-detail-placeholder');
    const machineDeviceEditor = document.getElementById('machine-device-editor');
    const editorDeviceName = document.getElementById('editor-device-name');
    const editorDevicePlatform = document.getElementById('editor-device-platform');
    const editorIosFields = document.getElementById('editor-ios-fields');
    const editorAndroidFields = document.getElementById('editor-android-fields');
    const editorName = document.getElementById('editor-name');
    const editorSimulator = document.getElementById('editor-simulator');
    const editorOs = document.getElementById('editor-os');
    const editorUdid = document.getElementById('editor-udid');
    const editorPort = document.getElementById('editor-port');
    const editorAvd = document.getElementById('editor-avd');
    const editorError = document.getElementById('editor-error');
    const editorConfirm = document.getElementById('editor-confirm');
    const editorCancel = document.getElementById('editor-cancel');
    const machineDeviceMenu = document.getElementById('machine-device-menu');
    const machineDeviceMenuItemBtn = document.getElementById('machine-device-menu-item');

    // 直近受信の machines 配列(machineProfileInfo)。空なら「マシンプロファイルなし」。
    let machineProfiles = [];
    let machineProfileHasError = false;
    // 現在選択中とみなすマシン名(select の値。machines が0件なら null)。
    let selectedMachine = null;
    // 選択中デバイス名の集合(要件5: 複数選択に対応するため Set)。通常クリックは「その1台だけを
    // 選択」(既にその1台だけの選択状態なら解除。従来のトグル感を維持)、Shift+クリックは
    // アンカー(deviceSelectionAnchor)からの範囲選択、Cmd/Ctrl+クリックは個別の追加/除外トグル
    // (Finder/VSCode のリストと同じ標準セマンティクス。2026-07-11 ユーザー指示)。マシン切替・
    // 一覧再描画で一覧から消えた名前は Set から取り除く(validateSelectedDeviceName)。
    // 右ペインの編集フォームはちょうど1台(size===1)のときだけ表示する。
    let selectedDeviceNames = new Set();
    // 範囲選択(Shift+クリック)の起点=直近に通常/Cmd(Ctrl)クリックした行の名前。Shift+クリック
    // 自体ではアンカーを動かさない(連続 Shift+クリックで同じ起点から範囲を伸縮できる)。
    // 一覧から消えたら validateSelectedDeviceName で null に戻す。
    let deviceSelectionAnchor = null;
    // macOS 判定(行の contextmenu リスナーで Ctrl+クリックを選択トグルへ振り分けるのに使う。
    // 下の toggleDeviceRowSelection まわりのコメント参照)。
    const isMacPlatform = /^Mac/.test(navigator.platform || '');
    // 直近描画したデバイス行の DOM 要素(name -> row)。トグル選択・右クリックメニューの
    // 対象存在チェックで、一覧全体を再描画せずに済ませるために使う。
    let deviceRowElements = new Map();
    // 右クリックメニュー(#machine-device-menu)を開いている対象(未オープンなら null)。
    // { machine, name } の形(deviceOpMenuEntry がタイル entry を保持するのと対応)。
    let machineDeviceMenuEntry = null;
    // 右ペインの編集フォームの対象({ machine, platform, originalName }。未選択なら null)。
    let editorTarget = null;
    // フォームを最後に作り直した(＝選択・machineProfileInfo再プリフィル)時点の6フィールド値。
    // dirty 判定(現在値との比較)・machineProfileInfo 再受信時の再プリフィル可否判定に使う。
    let editorOriginalValues = null;
    // いずれかのフィールドが元の値(editorOriginalValues)から変わっているか。
    let editorDirty = false;
    // machineDeviceUpdate の応答待ち中か(二重送信防止・machineProfileInfo 再受信時の
    // 再プリフィル抑止に使う)。
    let editorSubmitting = false;

    function findMachine(name) {
      return machineProfiles.find((m) => m.name === name);
    }

    // (デバイス一覧と右ペインの分割スプリッター(#profile-splitter)は 2026-07-11 ユーザー指示で
    // 廃止した。一覧幅は .machine-device-list の width: max-content で内容に自動フィットする。
    // 旧実装の persistedState.machineListWidth は読まなくなるだけで無害なので放置する。)

    // selectedDeviceNames のうち、現在の selectedMachine の一覧に存在しない名前を取り除く
    // (要件: マシン切替・一覧更新で選択中デバイスが消えた場合)。存在するものは維持する
    // (machineProfileInfo 再受信後も選択を名前で照合して引き継ぐ)。
    function validateSelectedDeviceName() {
      const machine = findMachine(selectedMachine);
      const names = new Set(machine ? machine.devices.map((d) => d.name) : []);
      for (const name of selectedDeviceNames) {
        if (!names.has(name)) {
          selectedDeviceNames.delete(name);
        }
      }
      // 範囲選択(Shift+クリック)の起点も同様に照合し、一覧から消えていたら捨てる
      // (アンカー不在時の Shift+クリックは通常クリック扱いになる)。
      if (deviceSelectionAnchor !== null && !names.has(deviceSelectionAnchor)) {
        deviceSelectionAnchor = null;
      }
    }

    // machineProfileInfo 受信のたびに selectedMachine を検証し、無効なら current→先頭の順で
    // フォールバックする(要件: 選択中マシンが一覧から消えた場合の復帰先)。
    function applyMachineProfileInfo(message) {
      machineProfiles = Array.isArray(message.machines) ? message.machines : [];
      const error = typeof message.error === 'string' ? message.error : null;
      const current = typeof message.current === 'string' ? message.current : null;
      machineProfileHasError = !!error;

      if (!findMachine(selectedMachine)) {
        if (current !== null && findMachine(current)) {
          selectedMachine = current;
        } else {
          selectedMachine = machineProfiles.length > 0 ? machineProfiles[0].name : null;
        }
      }

      validateSelectedDeviceName();
      renderMachineSelect();
      renderMachineProfileBody(error);
      refreshEditorAfterProfileInfo();
      // 「+新規作成」「+既存から選択」は同一条件で有効/無効を切り替える(要件1)。
      btnDeviceAddExisting.disabled = machineProfileHasError || machineProfiles.length === 0;
      // [+] はプロジェクトさえ解決できれば追加先があるので machines 件数は問わない。
      // [−]/[✏] は対象(selectedMachine)が要るので、machines が0件のときも無効化する。
      btnMachineAdd.disabled = machineProfileHasError;
      btnMachineCopy.disabled = machineProfileHasError || machineProfiles.length === 0;
      btnMachineRemove.disabled = machineProfileHasError || machineProfiles.length === 0;
      btnMachineRename.disabled = machineProfileHasError || machineProfiles.length === 0;
    }

    // 追加/名前変更の直後にホストから届く、選択を新プロファイルへ移す通知。直前の
    // machineProfileInfo とは順序が前後しない(postMessage は順序保証)ため、単純に上書きでよい。
    // エラー時(machineProfileHasError)にホストがこのメッセージを送ってくることは無い前提だが、
    // 念のため無視するガードを入れる。
    function applyMachineProfileSelected(message) {
      if (machineProfileHasError) {
        return;
      }
      selectedMachine = message.name;
      validateSelectedDeviceName();
      renderMachineSelect();
      renderMachineProfileBody(null);
    }

    function renderMachineSelect() {
      if (machineProfiles.length >= 1) {
        machineSelect.style.display = '';
        machineNameStatic.style.display = 'none';
        machineSelect.textContent = '';
        for (const machine of machineProfiles) {
          const option = document.createElement('option');
          option.value = machine.name;
          option.textContent = machine.name;
          machineSelect.appendChild(option);
        }
        machineSelect.value = selectedMachine || '';
      } else {
        machineSelect.style.display = 'none';
        machineNameStatic.style.display = '';
        machineNameStatic.textContent = '(マシンプロファイルなし)';
      }
    }

    machineSelect.addEventListener('change', () => {
      selectedMachine = machineSelect.value;
      validateSelectedDeviceName();
      renderMachineProfileBody(machineProfileHasError ? machineProfileError.textContent : null);
      // マシン切替は明示操作なので、編集途中の値を破棄してフォームを作り直す(要件2)。
      rebuildEditorForSelection();
    });

    btnMachineAdd.addEventListener('click', () => vscode.postMessage({ type: 'machineProfileAdd' }));
    btnMachineCopy.addEventListener('click', () => {
      if (selectedMachine) {
        vscode.postMessage({ type: 'machineProfileCopy', machine: selectedMachine });
      }
    });
    btnMachineRemove.addEventListener('click', () => {
      if (selectedMachine) {
        vscode.postMessage({ type: 'machineProfileDelete', machine: selectedMachine });
      }
    });
    btnMachineRename.addEventListener('click', () => {
      if (selectedMachine) {
        vscode.postMessage({ type: 'machineProfileRename', machine: selectedMachine });
      }
    });

    // 行クリックの選択(要件5。2026-07-11 ユーザー指示で Finder/VSCode のリストと同じ標準
    // セマンティクスに変更)。判定順は shiftKey → metaKey/ctrlKey → 通常(Shift+Cmd 同時は
    // Shift 扱い)。
    // - Shift+クリック: 表示順(deviceRowElements の挿入順=renderMachineProfileBody の描画順)で
    //   アンカー〜クリック行の間(両端含む)を選択に「置き換える」。アンカーは動かさない
    //   (連続 Shift+クリックで同じ起点から範囲を伸縮できる)。アンカーが無効(null/一覧に不在)
    //   なら通常クリックと同じ扱いにフォールバックする。
    // - Cmd(metaKey)/Ctrl(ctrlKey)+クリック: クリック行を個別に追加/除外するトグル(従来の
    //   Shift の挙動)。クリック行をアンカーに設定する。
    // - 通常クリック: その1台だけを選択(既存の選択を置き換える)+クリック行をアンカーに設定。
    //   既に「その1台だけが選択」状態なら解除する(従来のトグル感を維持。解除時はアンカーも null)。
    function toggleDeviceRowSelection(name, event) {
      const anchorValid = deviceSelectionAnchor !== null && deviceRowElements.has(deviceSelectionAnchor);
      if (event.shiftKey && anchorValid) {
        const order = [...deviceRowElements.keys()];
        const anchorIndex = order.indexOf(deviceSelectionAnchor);
        const clickedIndex = order.indexOf(name);
        const start = Math.min(anchorIndex, clickedIndex);
        const end = Math.max(anchorIndex, clickedIndex);
        selectedDeviceNames = new Set(order.slice(start, end + 1));
      } else if (!event.shiftKey && (event.metaKey || event.ctrlKey)) {
        if (selectedDeviceNames.has(name)) {
          selectedDeviceNames.delete(name);
        } else {
          selectedDeviceNames.add(name);
        }
        deviceSelectionAnchor = name;
      } else if (selectedDeviceNames.size === 1 && selectedDeviceNames.has(name)) {
        selectedDeviceNames.clear();
        deviceSelectionAnchor = null;
      } else {
        selectedDeviceNames = new Set([name]);
        deviceSelectionAnchor = name;
      }
      updateDeviceSelectionUi();
      // 選択変更は明示操作なので、編集途中の値を破棄してフォームを作り直す(要件2)。
      rebuildEditorForSelection();
    }

    function updateDeviceSelectionUi() {
      for (const [name, row] of deviceRowElements) {
        row.classList.toggle('selected', selectedDeviceNames.has(name));
      }
    }

    function renderMachineProfileBody(error) {
      if (error) {
        machineProfileBody.style.display = 'none';
        machineProfileError.style.display = 'flex';
        machineProfileError.textContent = error;
        machineDeviceList.textContent = '';
        deviceRowElements = new Map();
        closeMachineDeviceMenu();
        return;
      }
      machineProfileError.style.display = 'none';
      machineProfileBody.style.display = 'flex';

      const machine = findMachine(selectedMachine);
      const devices = machine ? machine.devices : [];
      machineDeviceList.textContent = '';
      deviceRowElements = new Map();
      if (devices.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'machine-device-empty';
        empty.textContent = 'デバイスがありません。上のボタンから追加できます。';
        machineDeviceList.appendChild(empty);
      } else {
        for (const device of devices) {
          const row = document.createElement('div');
          row.className = 'machine-device-row';
          const name = document.createElement('span');
          // タイル/レーンのデバイス名ピルと同じ配色クラスを再利用する(tile-name-ios/-android)。
          name.className = 'tile-name tile-name-' + device.platform;
          name.textContent = device.name;
          const detail = document.createElement('div');
          detail.className = 'machine-device-detail';
          detail.textContent = device.detail;
          row.append(name, detail);
          row.addEventListener('click', (event) => toggleDeviceRowSelection(device.name, event));
          row.addEventListener('contextmenu', (event) => {
            event.preventDefault();
            event.stopPropagation();
            // macOS では Ctrl+クリックが OS レベルで右クリック扱いになり click イベントは発生せず
            // contextmenu として届くため、ここで選択トグルへ振り分ける(2026-07-11 ユーザー要望:
            // Cmd と同様に Ctrl でも追加選択したい)。contextmenu イベントにも
            // shiftKey/ctrlKey/metaKey は載っているので event をそのまま渡せば既存の判定
            // (Shift優先→Ctrl/Cmdで個別トグル)がそのまま効く。mac では物理右クリック+Ctrl
            // 押下も選択トグルになるが、メニューは素の右クリックで開けるため許容。
            // Windows/Linux の Ctrl+クリックは通常の click イベントで既に対応済みなので、
            // この振り分けは mac のみ。
            if (isMacPlatform && event.ctrlKey) {
              toggleDeviceRowSelection(device.name, event);
              return;
            }
            // クリックした行が現在の複数選択(2台以上)に含まれる場合は選択中全台を対象にする。
            // それ以外は従来どおりクリックした行単体を対象にする(要件5)。選択状態自体は
            // 右クリックでは変更しない。
            const names =
              selectedDeviceNames.size >= 2 && selectedDeviceNames.has(device.name)
                ? [...selectedDeviceNames]
                : [device.name];
            openMachineDeviceMenu({ machine: selectedMachine, names }, event.clientX, event.clientY);
          });
          deviceRowElements.set(device.name, row);
          machineDeviceList.appendChild(row);
        }
      }
      // 一覧再描画で対象デバイス/マシンが変わった場合、開いたままの右クリックメニューを残さない。
      if (
        machineDeviceMenuEntry &&
        (machineDeviceMenuEntry.machine !== selectedMachine ||
          !machineDeviceMenuEntry.names.every((name) => deviceRowElements.has(name)))
      ) {
        closeMachineDeviceMenu();
      }
      updateDeviceSelectionUi();
    }

    // 選択中マシンの全デバイス名(ios/android 横断。デバイス追加モーダルの重複検証に使う)。
    function allDeviceNamesForSelectedMachine() {
      const machine = findMachine(selectedMachine);
      return machine ? machine.devices.map((d) => d.name) : [];
    }

    // ---- 右ペインの編集フォーム(要件2) ---------------------------------------------
    // 行選択中は #machine-device-editor を表示し、machineDeviceUpdate で machines/*.json を
    // 更新する。dirty(未確定の編集があるか)は6フィールドの現在値と、フォームを最後に作り直した
    // 時点の値(editorOriginalValues)を素の文字列比較するだけで判定する(trim はしない。
    // 「元の値から変わったか」という見た目上の判定であり、送信直前の検証・整形とは別の関心事)。

    const EDITOR_PLATFORM_LABEL = { ios: 'iOS', android: 'Android' };
    // input イベントを購読するのは編集可のフィールドだけ(機種/OS/UDID/AVD は選択・コピー可能な
    // ラベル表示(span)であり、値が変わることはない)。
    const editorFieldInputs = [editorName, editorPort];

    // machines/*.json のデバイス1件(machineProfileInfo の生フィールド付き)から、フォームの
    // 6フィールド分の文字列を組み立てる(undefined は空文字扱い。port は文字列化する)。
    function deviceFieldValues(device) {
      return {
        name: device.name,
        simulator: device.simulator || '',
        os: device.os || '',
        udid: device.udid || '',
        port: device.port === undefined || device.port === null ? '' : String(device.port),
        avd: device.avd || '',
      };
    }

    function currentEditorValues() {
      // 機種/OS/UDID/AVD はラベル表示(span)なので textContent から読む(変わることはないが、
      // dirty 判定の比較対象として editorOriginalValues と同じ6フィールドの形を保つ)。
      return {
        name: editorName.value,
        simulator: editorSimulator.textContent,
        os: editorOs.textContent,
        udid: editorUdid.textContent,
        port: editorPort.value,
        avd: editorAvd.textContent,
      };
    }

    function valuesEqual(a, b) {
      return (
        a.name === b.name &&
        a.simulator === b.simulator &&
        a.os === b.os &&
        a.udid === b.udid &&
        a.port === b.port &&
        a.avd === b.avd
      );
    }

    // dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する。
    // キャンセルは dirty の間だけ表示し(要件2)、送信中(editorSubmitting)は確定・キャンセルとも
    // 無効化する(確定は「確定中...」表示、キャンセルは表示は保ったまま押せなくする)。
    function refreshEditorButtonsUi() {
      editorConfirm.disabled = editorSubmitting || !editorDirty;
      editorCancel.style.display = editorDirty ? '' : 'none';
      editorCancel.disabled = editorSubmitting;
    }
    function setEditorDirty(dirty) {
      editorDirty = dirty;
      refreshEditorButtonsUi();
    }

    // 選択中デバイスの値でフォームを作り直す(編集途中の値は破棄する)。
    function renderDeviceEditor(machine, device) {
      editorTarget = { machine: machine, platform: device.platform, originalName: device.name };
      editorOriginalValues = deviceFieldValues(device);
      editorSubmitting = false;
      editorError.textContent = '';
      editorDeviceName.className = 'tile-name tile-name-' + device.platform;
      editorDeviceName.textContent = device.name;
      editorDevicePlatform.textContent = EDITOR_PLATFORM_LABEL[device.platform] || device.platform;
      editorName.value = editorOriginalValues.name;
      editorSimulator.textContent = editorOriginalValues.simulator;
      editorOs.textContent = editorOriginalValues.os;
      editorUdid.textContent = editorOriginalValues.udid;
      editorPort.value = editorOriginalValues.port;
      editorAvd.textContent = editorOriginalValues.avd;
      editorIosFields.style.display = device.platform === 'ios' ? '' : 'none';
      editorAndroidFields.style.display = device.platform === 'android' ? '' : 'none';
      editorConfirm.textContent = '確定';
      profileDetailPlaceholder.style.display = 'none';
      machineDeviceEditor.style.display = '';
      setEditorDirty(false);
    }

    // プレースホルダーの既定文言(HTML の初期テキストをそのまま使い回す。0台選択時に表示する)。
    const DEVICE_PLACEHOLDER_DEFAULT_TEXT = profileDetailPlaceholder.textContent;

    // text 省略時は既定文言(0台選択)。2台以上選択時は呼び出し側が件数入りの文言を渡す(要件5)。
    function clearDeviceEditor(text) {
      editorTarget = null;
      editorOriginalValues = null;
      editorSubmitting = false;
      machineDeviceEditor.style.display = 'none';
      profileDetailPlaceholder.style.display = '';
      profileDetailPlaceholder.textContent = text !== undefined ? text : DEVICE_PLACEHOLDER_DEFAULT_TEXT;
      setEditorDirty(false);
    }

    // 右ペインの編集フォームは「ちょうど1台選択」のときだけ表示する(要件5)。0台は既定の
    // プレースホルダー、2台以上は「<N>台選択中(右クリックで一括除去できます)」を表示する。
    function singleSelectedDevice() {
      if (selectedDeviceNames.size !== 1) {
        return null;
      }
      const machine = findMachine(selectedMachine);
      if (!machine) {
        return null;
      }
      const [name] = selectedDeviceNames;
      return machine.devices.find((d) => d.name === name) || null;
    }

    // 選択変更・マシン切替(明示操作)用: ちょうど1台選択中ならその値でフォームを作り直し、
    // それ以外(0台/2台以上)はプレースホルダーに戻す。編集途中の値は常に破棄する。
    function rebuildEditorForSelection() {
      if (selectedDeviceNames.size >= 2) {
        clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
        return;
      }
      const device = singleSelectedDevice();
      if (device) {
        renderDeviceEditor(selectedMachine, device);
      } else {
        clearDeviceEditor();
      }
    }

    // machineProfileInfo 再受信用: 選択中デバイスが消えていれば選択解除、存在してかつ未編集
    // (dirty でない・送信中でない)なら新データで再プリフィルする。編集中(dirty)なら入力値を
    // 保持する(watcher 経由の再送で入力が消えるのを防ぐ。要件2)。
    function refreshEditorAfterProfileInfo() {
      if (machineProfileHasError) {
        clearDeviceEditor();
        return;
      }
      if (selectedDeviceNames.size >= 2) {
        clearDeviceEditor(selectedDeviceNames.size + '台選択中(右クリックで一括除去できます)');
        return;
      }
      if (selectedDeviceNames.size === 0) {
        clearDeviceEditor();
        return;
      }
      const device = singleSelectedDevice();
      if (!device) {
        clearDeviceEditor();
        return;
      }
      if (!editorDirty && !editorSubmitting) {
        renderDeviceEditor(selectedMachine, device);
      }
    }

    function onEditorFieldInput() {
      if (!editorTarget || editorSubmitting) {
        return;
      }
      setEditorDirty(!valuesEqual(currentEditorValues(), editorOriginalValues));
      // 入力を変えたら前回のエラー表示は古くなるので消す(次の「確定」クリックで再検証される)。
      editorError.textContent = '';
    }
    for (const input of editorFieldInputs) {
      input.addEventListener('input', onEditorFieldInput);
    }

    // キャンセル: 編集を破棄して選択中デバイスの最新値でフォームを作り直す。machineProfiles は
    // 常に最新(watcher経由で追従)なので、rebuildEditorForSelection がそのまま
    // 「現在のファイル状態に戻す」動作になる(エラー表示のクリアも rebuildEditorForSelection
    // →renderDeviceEditor/clearDeviceEditor 内で行われる)。
    editorCancel.addEventListener('click', () => {
      if (editorCancel.disabled) {
        return;
      }
      rebuildEditorForSelection();
    });

    // 複製元: src/monitorModel.ts の updateDeviceInMachineProfile の検証部分。webview は CSP により
    // import 不可のため複製する(validateNewDeviceName の複製と同じ方針。ロジックを変更したら
    // 両方に反映すること)。
    function validateDeviceEditorFields(name) {
      if (name.length === 0) {
        return 'デバイス名を入力してください。';
      }
      const others = allDeviceNamesForSelectedMachine().filter((n) => n !== editorTarget.originalName);
      if (others.includes(name)) {
        return '「' + name + '」は既に存在します。';
      }
      if (editorTarget.platform === 'ios') {
        const portValue = editorPort.value.trim();
        // 注意: この関数は renderHtml のテンプレートリテラル内なので、正規表現の \d は \\d と
        // 書く必要がある(\d のままだと生成される webview JS では /^d+$/ になり、正しい数値入力を
        // 誤って弾くバグになる。v0.0.30 までの回帰)。
        if (portValue.length > 0 && (!/^\\d+$/.test(portValue) || Number(portValue) > 65535)) {
          return 'port は 0〜65535 の整数で入力してください。';
        }
      }
      return null;
    }

    editorConfirm.addEventListener('click', () => {
      if (editorConfirm.disabled || editorSubmitting || !editorTarget) {
        return;
      }
      const name = editorName.value.trim();
      const validationError = validateDeviceEditorFields(name);
      if (validationError) {
        editorError.textContent = validationError;
        return;
      }
      editorSubmitting = true;
      editorConfirm.textContent = '確定中...';
      editorError.textContent = '';
      refreshEditorButtonsUi();
      vscode.postMessage({
        type: 'machineDeviceUpdate',
        machine: editorTarget.machine,
        platform: editorTarget.platform,
        originalName: editorTarget.originalName,
        fields: {
          name: name,
          // 編集不可フィールドはラベル表示(span)の textContent = 元の値をそのまま往復させる。
          simulator: editorTarget.platform === 'ios' ? editorSimulator.textContent.trim() : '',
          os: editorTarget.platform === 'ios' ? editorOs.textContent.trim() : '',
          udid: editorTarget.platform === 'ios' ? editorUdid.textContent.trim() : '',
          port: editorTarget.platform === 'ios' ? editorPort.value.trim() : '',
          avd: editorTarget.platform === 'android' ? editorAvd.textContent.trim() : '',
        },
      });
    });

    // machineDeviceUpdate の結果(ok:true ならリネーム追従+一覧/フォームは直後の
    // machineProfileInfo 再送(refreshEditorAfterProfileInfo)で最新化される。ok:false なら
    // エラー表示のみで、入力値はそのまま残す=再操作可能)。
    function applyMachineDeviceUpdateResult(message) {
      editorSubmitting = false;
      editorConfirm.textContent = '確定';
      if (message.ok) {
        selectedDeviceNames = new Set([message.name]);
        editorError.textContent = '';
        setEditorDirty(false);
      } else {
        refreshEditorButtonsUi();
        editorError.textContent = message.error || 'デバイスの更新に失敗しました。';
      }
    }

    // ---- デバイス行の右クリックメニュー(除去) -------------------------------------
    // 見た目・挙動はタイルの #device-op-menu(openDeviceOpMenu/closeDeviceOpMenu)を踏襲するが、
    // 状態(machineDeviceMenuEntry)・DOM要素は独立させる(タイルメニューの挙動に影響しないため)。

    function closeMachineDeviceMenu() {
      if (!machineDeviceMenuEntry) {
        return;
      }
      machineDeviceMenuEntry = null;
      machineDeviceMenu.classList.remove('visible');
    }

    // entry は { machine, names }(names は1件以上)。複数選択(2台以上)を対象にする場合は
    // メニュー項目のラベルを「選択した<N>台を除去」に変える(要件5)。
    function openMachineDeviceMenu(entry, clientX, clientY) {
      machineDeviceMenuEntry = entry;
      machineDeviceMenuItemBtn.textContent =
        entry.names.length >= 2 ? '選択した' + entry.names.length + '台を除去' : '除去';
      machineDeviceMenu.classList.add('visible');
      clampMenuPosition(machineDeviceMenu, clientX, clientY);
    }

    machineDeviceMenuItemBtn.addEventListener('click', (event) => {
      event.stopPropagation();
      if (!machineDeviceMenuEntry) {
        return;
      }
      vscode.postMessage({
        type: 'machineDeviceRemove',
        machine: machineDeviceMenuEntry.machine,
        names: machineDeviceMenuEntry.names,
      });
      closeMachineDeviceMenu();
    });

    // 外クリック・Esc・スクロール・リサイズで閉じる(#device-op-menu と同じ方針だが、
    // 独立したリスナーとして登録する)。
    document.addEventListener('click', (event) => {
      if (machineDeviceMenuEntry && !machineDeviceMenu.contains(event.target)) {
        closeMachineDeviceMenu();
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeMachineDeviceMenu();
      }
    });
    document.addEventListener('scroll', () => closeMachineDeviceMenu(), true);
    window.addEventListener('resize', () => closeMachineDeviceMenu());
    // 行上の contextmenu は stopPropagation 済みなのでここには来ない(行外で右クリックした
    // 場合に残さないためのガード。#device-op-menu の同種ハンドラと同じ理由)。
    document.addEventListener('contextmenu', () => closeMachineDeviceMenu());

    // ---- プロファイルタブ中段: アプリプロファイルの設定フォーム -----------------------
    // 一覧・初期選択は既存 profileInfo(applyProfileInfo/applyRunProfileInfo とは独立に
    // applyAppProfileInfo で受ける。message.apps を使う)。この選択は webview 内だけで完結し、
    // 他のどの設定にも連動しない(実行プロファイルセクションと違い「現在値」に相当する設定が
    // 無いため、フォールバックは常に一覧の先頭)。dirty 管理・再ロードの方針は実行プロファイル
    // セクション(下記)と同じ:
    // - フォーム値と appProfileOriginalFields の比較で「確定」を有効化。
    // - 選択変更(明示操作)で編集破棄して再ロード。
    // - profileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、未編集なら再ロード。
    //   編集対象が一覧から消えたらフォールバック(先頭)。
    // - appProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。
    // クライアント側の必須検証は無い(common/ios/android の全フィールドが省略可のため。
    // Swift 側 validate-profile の役割)。

    const appProfileSelect = document.getElementById('app-profile-select');
    const appProfileNameStatic = document.getElementById('app-profile-name-static');
    const btnAppProfileAdd = document.getElementById('btn-app-profile-add');
    const btnAppProfileCopy = document.getElementById('btn-app-profile-copy');
    const btnAppProfileRemove = document.getElementById('btn-app-profile-remove');
    const btnAppProfileRename = document.getElementById('btn-app-profile-rename');
    const appProfilePlaceholder = document.getElementById('app-profile-placeholder');
    const appProfileEditor = document.getElementById('app-profile-editor');
    const appProfileError = document.getElementById('app-profile-error');
    const appProfileConfirm = document.getElementById('app-profile-confirm');
    const appProfileCancel = document.getElementById('app-profile-cancel');

    // common/ios/android それぞれの DOM 参照をまとめて持つ(renderAppProfileEditor・
    // collectAppProfileFields・appProfileValuesEqual・setAppProfileControlsEnabled が使う)。
    // common は表示名(appName)+自動インストールのチェックボックス(heal と同じマークアップ。
    // 既定=チェックOFF=無効)、ios/android は app/appPath が廃止されフォーム自体に無いため
    // 表示名/アプリID/パッケージパスの3項目のみ(自動インストールを common に一本化した
    // 2026-07-11 指示に伴い、以前ここにあった autoInstall チェックボックスは common へ移設)。
    const appProfileGroups = {
      common: {
        appName: document.getElementById('app-profile-common-app-name'),
        autoInstall: document.getElementById('app-profile-common-auto-install'),
      },
      ios: {
        appName: document.getElementById('app-profile-ios-app-name'),
        app: document.getElementById('app-profile-ios-app'),
        appPath: document.getElementById('app-profile-ios-app-path'),
      },
      android: {
        appName: document.getElementById('app-profile-android-app-name'),
        app: document.getElementById('app-profile-android-app'),
        appPath: document.getElementById('app-profile-android-app-path'),
      },
    };
    const APP_PROFILE_GROUP_NAMES = ['common', 'ios', 'android'];
    // app/appPath を持つのは ios/android のみ(common には無い)。
    const APP_PROFILE_PLATFORM_GROUP_NAMES = ['ios', 'android'];

    // 自動インストールはチェックボックス1つで内部表現("true"/"false")の読み書きを行う
    // (monitorModel.ts の AppProfileCommonFields.autoInstall と同じ2値の文字列。common に
    // 一本化される前は AppProfilePlatformFields.autoInstall として ios/android 別に持っていたが、
    // dom.autoInstall を読み書きする形自体は変わらないため、呼び出し側を
    // appProfileGroups.common に変えるだけで済んだ。保存意味論(true→autoInstall:trueをセット、
    // false→キー削除)も不変)。
    function getAppProfileAutoInstall(dom) {
      return dom.autoInstall.checked ? 'true' : 'false';
    }
    function setAppProfileAutoInstall(dom, value) {
      dom.autoInstall.checked = value === 'true';
    }

    // 直近受信の一覧(profileInfo.apps 由来)。
    let appProfileNames = [];
    // 編集対象のアプリプロファイル名(一覧が0件なら null)。
    let selectedAppProfile = null;
    // 直近ロード(appProfileData ok:true)時点のフィールド値。null の間はフォーム非表示。
    let appProfileOriginalFields = null;
    let appProfileDirty = false;
    let appProfileSubmitting = false;

    function appProfileEditing() {
      return appProfileDirty || appProfileSubmitting;
    }

    // dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
    // (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
    function refreshAppProfileButtonsUi() {
      appProfileConfirm.disabled = appProfileSubmitting || !appProfileDirty;
      appProfileCancel.style.display = appProfileDirty ? '' : 'none';
      appProfileCancel.disabled = appProfileSubmitting;
    }
    function setAppProfileDirty(dirty) {
      appProfileDirty = dirty;
      refreshAppProfileButtonsUi();
    }

    function showAppProfilePlaceholder(text) {
      appProfileOriginalFields = null;
      appProfileSubmitting = false;
      appProfileEditor.style.display = 'none';
      appProfilePlaceholder.style.display = '';
      appProfilePlaceholder.textContent = text;
      setAppProfileDirty(false);
    }

    function requestAppProfileLoad() {
      if (!selectedAppProfile) {
        showAppProfilePlaceholder('アプリプロファイルがありません。');
        return;
      }
      // 応答(appProfileData)が来るまで編集させない(requestRunProfileLoad と同じ理由)。
      showAppProfilePlaceholder('読み込み中...');
      vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
    }

    // profileInfo 受信(applyProfileInfo/applyRunProfileInfo と独立)。選択の維持/フォールバックと
    // 再ロードを行う。「現在値」に相当する設定が無いため、applyRunProfileInfo と違い先頭への
    // フォールバックのみ。
    function applyAppProfileInfo(message) {
      appProfileNames = Array.isArray(message.apps) ? message.apps : [];

      const previous = selectedAppProfile;
      if (selectedAppProfile === null || !appProfileNames.includes(selectedAppProfile)) {
        selectedAppProfile = appProfileNames.length > 0 ? appProfileNames[0] : null;
      }
      renderAppProfileSelect();
      // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
      // コピー/−/✏ は対象(選択中のアプリプロファイル)が要るので、一覧0件のときは無効化する
      // (applyRunProfileInfo と同じ方針)。
      btnAppProfileAdd.disabled = false;
      btnAppProfileCopy.disabled = appProfileNames.length === 0;
      btnAppProfileRemove.disabled = appProfileNames.length === 0;
      btnAppProfileRename.disabled = appProfileNames.length === 0;

      if (selectedAppProfile !== previous) {
        requestAppProfileLoad();
        return;
      }
      if (selectedAppProfile !== null && !appProfileEditing()) {
        requestAppProfileLoad();
      } else if (selectedAppProfile === null) {
        showAppProfilePlaceholder('アプリプロファイルがありません。');
      }
    }

    function renderAppProfileSelect() {
      if (appProfileNames.length >= 1) {
        appProfileSelect.style.display = '';
        appProfileNameStatic.style.display = 'none';
        appProfileSelect.textContent = '';
        for (const name of appProfileNames) {
          const option = document.createElement('option');
          option.value = name;
          option.textContent = name;
          appProfileSelect.appendChild(option);
        }
        appProfileSelect.value = selectedAppProfile || '';
      } else {
        appProfileSelect.style.display = 'none';
        appProfileNameStatic.style.display = '';
      }
    }

    appProfileSelect.addEventListener('change', () => {
      // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
      selectedAppProfile = appProfileSelect.value;
      requestAppProfileLoad();
    });

    btnAppProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'appProfileAdd' }));
    btnAppProfileCopy.addEventListener('click', () => {
      if (selectedAppProfile) {
        vscode.postMessage({ type: 'appProfileCopy', profile: selectedAppProfile });
      }
    });
    btnAppProfileRemove.addEventListener('click', () => {
      if (selectedAppProfile) {
        vscode.postMessage({ type: 'appProfileDelete', profile: selectedAppProfile });
      }
    });
    btnAppProfileRename.addEventListener('click', () => {
      if (selectedAppProfile) {
        vscode.postMessage({ type: 'appProfileRename', profile: selectedAppProfile });
      }
    });

    // 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
    // (applyRunProfileSelected と同じ趣旨)。
    function applyAppProfileSelected(message) {
      if (!appProfileNames.includes(message.name)) {
        return;
      }
      selectedAppProfile = message.name;
      renderAppProfileSelect();
      requestAppProfileLoad();
    }

    // appProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(applyRunProfileData と
    // 同じガード)。
    function applyAppProfileData(message) {
      if (message.profile !== selectedAppProfile) {
        return;
      }
      if (appProfileEditing()) {
        return;
      }
      if (!message.ok || !message.fields) {
        showAppProfilePlaceholder(message.error || 'アプリプロファイルを読み込めませんでした。');
        return;
      }
      renderAppProfileEditor(message.fields);
    }

    // iOS/Android の表示名(appName)入力欄のプレースホルダーに、共通(common)の表示名フィールドの
    // 現在の入力値を表示する。appName は common → platform の順で後勝ちマージされるため、platform
    // 側が空欄のときの実効値は common の値になる — その「継承される値」をウォーターマークとして
    // 見せることで、空欄の意味(未入力=common の値がそのまま使われる)を一目で分かるようにする。
    // 共通の表示名が空ならプレースホルダーも空でよい(素の value をそのまま使う)。
    function updateAppProfileNamePlaceholders() {
      const inherited = appProfileGroups.common.appName.value;
      for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
        appProfileGroups[group].appName.placeholder = inherited;
      }
    }

    // ロード済みの値でフォームを作り直す(編集途中の値は破棄する)。
    function renderAppProfileEditor(fields) {
      appProfileOriginalFields = fields;
      appProfileSubmitting = false;
      appProfileError.textContent = '';

      // 表示名(appName)は common/ios/android 共通で持つ唯一のフィールドなので3グループまとめて
      // 設定する。
      for (const group of APP_PROFILE_GROUP_NAMES) {
        appProfileGroups[group].appName.value = fields[group].appName;
      }
      // 自動インストールは common に一本化されている(2026-07-11 指示)。
      setAppProfileAutoInstall(appProfileGroups.common, fields.common.autoInstall);
      // アプリID・パッケージパスは ios/android のみ(common には無い)。
      for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
        const dom = appProfileGroups[group];
        const values = fields[group];
        dom.app.value = values.app;
        dom.appPath.value = values.appPath;
      }
      // プリフィル直後の共通表示名を反映してプレースホルダーを初期化する。
      updateAppProfileNamePlaceholders();

      setAppProfileControlsEnabled(true);
      appProfileConfirm.textContent = '確定';
      appProfilePlaceholder.style.display = 'none';
      appProfileEditor.style.display = '';
      setAppProfileDirty(false);
    }

    // 現在のフォーム入力値を、appProfileSave の fields と同じ形(common は表示名+自動インストールの
    // 2項目、ios/android は表示名/アプリID/パッケージパスの3項目。text 系は trim 済み)で集める。
    function collectAppProfileFields() {
      const fields = {
        common: {
          appName: appProfileGroups.common.appName.value.trim(),
          autoInstall: getAppProfileAutoInstall(appProfileGroups.common),
        },
      };
      for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
        const dom = appProfileGroups[group];
        fields[group] = {
          appName: dom.appName.value.trim(),
          app: dom.app.value.trim(),
          appPath: dom.appPath.value.trim(),
        };
      }
      return fields;
    }

    function appProfileValuesEqual(fields) {
      const current = collectAppProfileFields();
      if (
        current.common.appName !== fields.common.appName ||
        current.common.autoInstall !== fields.common.autoInstall
      ) {
        return false;
      }
      return APP_PROFILE_PLATFORM_GROUP_NAMES.every((group) => {
        const a = current[group];
        const b = fields[group];
        return a.appName === b.appName && a.app === b.app && a.appPath === b.appPath;
      });
    }

    function onAppProfileFormInput() {
      if (appProfileOriginalFields === null || appProfileSubmitting) {
        return;
      }
      setAppProfileDirty(!appProfileValuesEqual(appProfileOriginalFields));
      // 入力を変えたら前回のエラー表示は古くなるので消す(runProfileError と同じ方針)。
      appProfileError.textContent = '';
    }

    for (const group of APP_PROFILE_GROUP_NAMES) {
      appProfileGroups[group].appName.addEventListener('input', onAppProfileFormInput);
    }
    appProfileGroups.common.autoInstall.addEventListener('change', onAppProfileFormInput);
    // 共通の表示名を編集するたび、iOS/Android のプレースホルダー(継承値のライブプレビュー)を
    // 更新する。
    appProfileGroups.common.appName.addEventListener('input', updateAppProfileNamePlaceholders);
    for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
      const dom = appProfileGroups[group];
      dom.app.addEventListener('input', onAppProfileFormInput);
      dom.appPath.addEventListener('input', onAppProfileFormInput);
    }

    function setAppProfileControlsEnabled(enabled) {
      for (const group of APP_PROFILE_GROUP_NAMES) {
        appProfileGroups[group].appName.disabled = !enabled;
      }
      appProfileGroups.common.autoInstall.disabled = !enabled;
      for (const group of APP_PROFILE_PLATFORM_GROUP_NAMES) {
        const dom = appProfileGroups[group];
        dom.app.disabled = !enabled;
        dom.appPath.disabled = !enabled;
      }
    }

    appProfileConfirm.addEventListener('click', () => {
      if (appProfileConfirm.disabled || appProfileSubmitting || !selectedAppProfile) {
        return;
      }
      appProfileSubmitting = true;
      setAppProfileControlsEnabled(false);
      appProfileConfirm.textContent = '確定中...';
      appProfileError.textContent = '';
      refreshAppProfileButtonsUi();
      vscode.postMessage({
        type: 'appProfileSave',
        profile: selectedAppProfile,
        fields: collectAppProfileFields(),
      });
    });

    // キャンセル: dirty/送信中フラグを先に解除してから appProfileLoad を再送する
    // (applyAppProfileData は appProfileEditing() の間は応答を無視するガードがあるため、
    // 先に解除しておかないと再ロード結果が反映されない)。requestAppProfileLoad は内部で
    // showAppProfilePlaceholder→setAppProfileDirty(false) を呼ぶため、この順序を満たす。
    appProfileCancel.addEventListener('click', () => {
      if (appProfileCancel.disabled) {
        return;
      }
      appProfileError.textContent = '';
      requestAppProfileLoad();
    });

    // appProfileSave の結果。ok なら dirty 解除(ホストが続けて appProfileData を送るので、
    // フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
    function applyAppProfileSaveResult(message) {
      if (message.profile !== selectedAppProfile) {
        return;
      }
      appProfileSubmitting = false;
      appProfileConfirm.textContent = '確定';
      setAppProfileControlsEnabled(true);
      if (message.ok) {
        appProfileError.textContent = '';
        setAppProfileDirty(false);
      } else {
        refreshAppProfileButtonsUi();
        appProfileError.textContent = message.error || 'アプリプロファイルの更新に失敗しました。';
      }
    }

    // apps/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
    // 再ロードして自動反映する(applyRunProfileFileChanged と同じ方針)。
    function applyAppProfileFileChanged(message) {
      if (message.name === selectedAppProfile && !appProfileEditing()) {
        vscode.postMessage({ type: 'appProfileLoad', profile: selectedAppProfile });
      }
    }

    // ---- プロファイルタブ上段: 実行プロファイルの設定フォーム -----------------------
    // 一覧・初期選択は既存 profileInfo(applyProfileInfo とは独立に applyRunProfileInfo で受ける)。
    // この選択は「編集対象」であり ftester.profile 設定には触れない(デバイスタブのドロップダウン
    // とは独立)。dirty 管理はマシンプロファイルのデバイス編集フォームと同じ方針:
    // - フォーム値と runProfileOriginalFields の比較で「確定」を有効化。
    // - 選択変更(明示操作)で編集破棄して再ロード。
    // - profileInfo/machineProfileInfo 再受信時、編集中(dirty/送信中)ならフォーム値保持、
    //   未編集なら再ロード/再描画。編集対象が一覧から消えたらフォールバック(current→先頭)。
    // - runProfileFileChanged(外部編集)は編集対象と同名 && 未編集のときのみ再ロード。

    const runProfileSelect = document.getElementById('run-profile-select');
    const runProfileNameStatic = document.getElementById('run-profile-name-static');
    const btnRunProfileAdd = document.getElementById('btn-run-profile-add');
    const btnRunProfileCopy = document.getElementById('btn-run-profile-copy');
    const btnRunProfileRemove = document.getElementById('btn-run-profile-remove');
    const btnRunProfileRename = document.getElementById('btn-run-profile-rename');
    const runProfilePlaceholder = document.getElementById('run-profile-placeholder');
    const runProfileEditor = document.getElementById('run-profile-editor');
    const runProfileMachine = document.getElementById('run-profile-machine');
    const runProfileApp = document.getElementById('run-profile-app');
    const runProfileDevices = document.getElementById('run-profile-devices');
    const runProfileHeal = document.getElementById('run-profile-heal');
    const runProfileReportDir = document.getElementById('run-profile-report-dir');
    const runProfileDefaultTimeout = document.getElementById('run-profile-default-timeout');
    const runProfileError = document.getElementById('run-profile-error');
    const runProfileConfirm = document.getElementById('run-profile-confirm');
    const runProfileCancel = document.getElementById('run-profile-cancel');

    // 直近受信の一覧(profileInfo 由来)。
    let runProfileNames = [];
    let runProfileApps = [];
    // 編集対象の実行プロファイル名(一覧が0件なら null)。
    let selectedRunProfile = null;
    // 直近ロード(runProfileData ok:true)時点の6フィールド値。null の間はフォーム非表示。
    let runProfileOriginalFields = null;
    // 現在チェック済みのデバイス名(表示順。チェックボックス操作・machine切替の引き継ぎの正)。
    let runProfileCheckedNames = [];
    let runProfileDirty = false;
    let runProfileSubmitting = false;

    function runProfileEditing() {
      return runProfileDirty || runProfileSubmitting;
    }

    // dirty(=確定ボタン有効)と、それに連動する確定/キャンセルボタンの見た目をまとめて更新する
    // (editorForm の refreshEditorButtonsUi/setEditorDirty と同じ方針)。
    function refreshRunProfileButtonsUi() {
      runProfileConfirm.disabled = runProfileSubmitting || !runProfileDirty;
      runProfileCancel.style.display = runProfileDirty ? '' : 'none';
      runProfileCancel.disabled = runProfileSubmitting;
    }
    function setRunProfileDirty(dirty) {
      runProfileDirty = dirty;
      refreshRunProfileButtonsUi();
    }

    function showRunProfilePlaceholder(text) {
      runProfileOriginalFields = null;
      runProfileSubmitting = false;
      runProfileEditor.style.display = 'none';
      runProfilePlaceholder.style.display = '';
      runProfilePlaceholder.textContent = text;
      setRunProfileDirty(false);
    }

    function requestRunProfileLoad() {
      if (!selectedRunProfile) {
        showRunProfilePlaceholder('実行プロファイルがありません。');
        return;
      }
      // 応答(runProfileData)が来るまで編集させない(応答前の編集がロード結果に上書きされる
      // レースを避ける。ローカルファイル読みなので一瞬で置き換わる)。
      showRunProfilePlaceholder('読み込み中...');
      vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
    }

    // profileInfo 受信(applyProfileInfo と独立)。選択の維持/フォールバックと再ロードを行う。
    function applyRunProfileInfo(message) {
      runProfileNames = Array.isArray(message.profiles) ? message.profiles : [];
      // apps は後方互換(古いホストからは届かない)のため配列でなければ空扱い。
      runProfileApps = Array.isArray(message.apps) ? message.apps : [];
      const current = typeof message.current === 'string' ? message.current : '';

      const previous = selectedRunProfile;
      if (selectedRunProfile === null || !runProfileNames.includes(selectedRunProfile)) {
        // 編集対象が未定/一覧から消えた: current→先頭の順でフォールバック(編集破棄)。
        if (current !== '' && runProfileNames.includes(current)) {
          selectedRunProfile = current;
        } else {
          selectedRunProfile = runProfileNames.length > 0 ? runProfileNames[0] : null;
        }
      }
      renderRunProfileSelect();
      // [+] は profileInfo を受信できた時点で追加先(プロジェクト)があるので常に有効。
      // コピー/−/✏ は対象(選択中の実行プロファイル)が要るので、一覧0件のときは無効化する
      // (マシンプロファイルの btnMachineCopy/Remove/Rename と同じ方針)。
      btnRunProfileAdd.disabled = false;
      btnRunProfileCopy.disabled = runProfileNames.length === 0;
      btnRunProfileRemove.disabled = runProfileNames.length === 0;
      btnRunProfileRename.disabled = runProfileNames.length === 0;

      if (selectedRunProfile !== previous) {
        requestRunProfileLoad();
        return;
      }
      // 選択が変わらない場合: 編集中ならフォーム値を保持し、未編集なら再ロードして最新化する
      // (apps 一覧の変化もロード後の再描画で反映される)。
      if (selectedRunProfile !== null && !runProfileEditing()) {
        requestRunProfileLoad();
      } else if (selectedRunProfile === null) {
        showRunProfilePlaceholder('実行プロファイルがありません。');
      }
    }

    function renderRunProfileSelect() {
      if (runProfileNames.length >= 1) {
        runProfileSelect.style.display = '';
        runProfileNameStatic.style.display = 'none';
        runProfileSelect.textContent = '';
        for (const name of runProfileNames) {
          const option = document.createElement('option');
          option.value = name;
          option.textContent = name;
          runProfileSelect.appendChild(option);
        }
        runProfileSelect.value = selectedRunProfile || '';
      } else {
        runProfileSelect.style.display = 'none';
        runProfileNameStatic.style.display = '';
      }
    }

    runProfileSelect.addEventListener('change', () => {
      // 選択変更は明示操作なので、編集途中の値を破棄して選択先を再ロードする。
      selectedRunProfile = runProfileSelect.value;
      requestRunProfileLoad();
    });

    btnRunProfileAdd.addEventListener('click', () => vscode.postMessage({ type: 'profileAdd' }));
    btnRunProfileCopy.addEventListener('click', () => {
      if (selectedRunProfile) {
        vscode.postMessage({ type: 'profileCopy', profile: selectedRunProfile });
      }
    });
    btnRunProfileRemove.addEventListener('click', () => {
      if (selectedRunProfile) {
        vscode.postMessage({ type: 'profileDelete', profile: selectedRunProfile });
      }
    });
    btnRunProfileRename.addEventListener('click', () => {
      if (selectedRunProfile) {
        vscode.postMessage({ type: 'profileRename', profile: selectedRunProfile });
      }
    });

    // 追加/コピー/名前変更の直後にホストから届く、選択(編集対象)を新プロファイルへ移す通知
    // (machineProfileSelected と同じ趣旨)。直前の profileInfo とは順序が前後しない
    // (postMessage は順序保証)ため単純に上書きでよいが、念のため一覧に無い名前は無視するガードを
    // 入れる(applyRunProfileInfo のフォールバック判定と同じ runProfileNames.includes を使う)。
    function applyRunProfileSelected(message) {
      if (!runProfileNames.includes(message.name)) {
        return;
      }
      selectedRunProfile = message.name;
      renderRunProfileSelect();
      requestRunProfileLoad();
    }

    // machineProfileInfo 再受信時(メッセージスイッチから呼ばれる): 未編集ならロード済みの値で
    // フォームを作り直す(マシン一覧・デバイス一覧の変化を反映)。編集中なら入力値を保持する。
    function rerenderRunProfileFormIfClean() {
      if (runProfileOriginalFields !== null && !runProfileEditing()) {
        renderRunProfileEditor(runProfileOriginalFields);
      }
    }

    // runProfileData 受信: 編集対象と同じプロファイルの応答のみ反映する(選択変更直後に届く
    // 前の選択への応答を無視するガード)。
    function applyRunProfileData(message) {
      if (message.profile !== selectedRunProfile) {
        return;
      }
      // 編集中(dirty/送信中)は反映しない(保存成功直後の再送は dirty 解除済みなので反映される)。
      if (runProfileEditing()) {
        return;
      }
      if (!message.ok || !message.fields) {
        showRunProfilePlaceholder(message.error || '実行プロファイルを読み込めませんでした。');
        return;
      }
      renderRunProfileEditor(message.fields);
    }

    // ロード済みの6フィールド値でフォームを作り直す(編集途中の値は破棄する)。
    function renderRunProfileEditor(fields) {
      runProfileOriginalFields = fields;
      runProfileSubmitting = false;
      runProfileError.textContent = '';

      renderRunProfileMachineSelect(fields.machine);
      renderRunProfileAppSelect(fields.app);
      runProfileCheckedNames = fields.devices.slice();
      renderRunProfileDevices();
      runProfileHeal.checked = fields.heal;
      runProfileReportDir.value = fields.reportDir;
      runProfileDefaultTimeout.value = fields.defaultTimeout;

      setRunProfileControlsEnabled(true);
      runProfileConfirm.textContent = '確定';
      runProfilePlaceholder.style.display = 'none';
      runProfileEditor.style.display = '';
      setRunProfileDirty(false);
    }

    // 「使用するマシンプロファイル」select。選択肢 = machineProfiles(machineProfileInfo 由来)の
    // 名前。value が未指定("")/一覧に無い場合は先頭に「(未指定)」(value="")を付け、一覧に無い
    // 非空値はオプション補完で表示する(デバイスタブの applyProfileInfo の unknownOption と同じ方針)。
    function renderRunProfileMachineSelect(value) {
      runProfileMachine.textContent = '';
      const names = machineProfiles.map((m) => m.name);
      if (value === '' || !names.includes(value)) {
        const unspecified = document.createElement('option');
        unspecified.value = '';
        unspecified.textContent = '(未指定)';
        runProfileMachine.appendChild(unspecified);
      }
      for (const name of names) {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        runProfileMachine.appendChild(option);
      }
      if (value !== '' && !names.includes(value)) {
        const unknown = document.createElement('option');
        unknown.value = value;
        unknown.textContent = value;
        runProfileMachine.appendChild(unknown);
      }
      runProfileMachine.value = value;
    }

    // 「アプリ」select。選択肢 = profileInfo.apps。現在値が一覧に無ければオプション補完する。
    function renderRunProfileAppSelect(value) {
      runProfileApp.textContent = '';
      let matched = value === '';
      // 空文字(未指定)の option を常に先頭に置く(app 欠落プロファイルの現在値を表せるように。
      // 空のまま確定しようとするとクライアント検証で弾かれる)。
      const emptyOption = document.createElement('option');
      emptyOption.value = '';
      emptyOption.textContent = '(未指定)';
      runProfileApp.appendChild(emptyOption);
      for (const name of runProfileApps) {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        runProfileApp.appendChild(option);
        if (name === value) {
          matched = true;
        }
      }
      if (!matched) {
        const unknown = document.createElement('option');
        unknown.value = value;
        unknown.textContent = value;
        runProfileApp.appendChild(unknown);
      }
      runProfileApp.value = value;
    }

    // デバイスのチェックボックス一覧。選択肢 = フォームで選択中のマシンプロファイルのデバイス。
    // runProfileCheckedNames に含まれる名前はチェック済み。チェック済みだがマシンに存在しない
    // 名前は末尾に注記付きで表示する(チェックを外して確定すれば取り除ける)。マシン未指定("")の
    // 間は案内のみ表示する。
    function renderRunProfileDevices() {
      runProfileDevices.textContent = '';
      const machineName = runProfileMachine.value;
      if (machineName === '') {
        const note = document.createElement('div');
        note.className = 'run-profile-device-note';
        note.textContent = 'マシンプロファイルを指定するとデバイスを選択できます';
        runProfileDevices.appendChild(note);
        return;
      }
      const machine = findMachine(machineName);
      const machineDevices = machine ? machine.devices : [];
      const machineDeviceNames = machineDevices.map((d) => d.name);
      const appendRow = (name, platform, missing) => {
        const row = document.createElement('label');
        row.className = 'run-profile-device-row';
        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.checked = runProfileCheckedNames.includes(name);
        checkbox.dataset.deviceName = name;
        checkbox.addEventListener('change', onRunProfileDeviceToggle);
        const pill = document.createElement('span');
        // タイル/レーンと同じ配色ピル(.tile-name-ios/-android)。マシンに存在しない名前は
        // プラットフォームが分からないので中立色(.tile-name-unknown)にする。
        pill.className = 'tile-name ' + (platform ? 'tile-name-' + platform : 'tile-name-unknown');
        pill.textContent = name;
        row.append(checkbox, pill);
        if (missing) {
          const note = document.createElement('span');
          note.className = 'run-profile-device-note';
          note.textContent = '(マシンプロファイルにありません)';
          row.appendChild(note);
        }
        runProfileDevices.appendChild(row);
      };
      for (const device of machineDevices) {
        appendRow(device.name, device.platform, false);
      }
      for (const name of runProfileCheckedNames) {
        if (!machineDeviceNames.includes(name)) {
          appendRow(name, null, true);
        }
      }
    }

    // チェックボックス操作: DOM の表示順(マシンのデバイス順+欠落分)で checked を集め直す。
    function onRunProfileDeviceToggle() {
      const checked = [];
      for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
        if (checkbox.checked) {
          checked.push(checkbox.dataset.deviceName);
        }
      }
      runProfileCheckedNames = checked;
      onRunProfileFormInput();
    }

    // マシン切替: チェック状態(runProfileCheckedNames)は名前で引き継いだまま一覧を作り直す。
    runProfileMachine.addEventListener('change', () => {
      renderRunProfileDevices();
      onRunProfileFormInput();
    });
    runProfileApp.addEventListener('change', onRunProfileFormInput);
    runProfileHeal.addEventListener('change', onRunProfileFormInput);
    runProfileReportDir.addEventListener('input', onRunProfileFormInput);
    runProfileDefaultTimeout.addEventListener('input', onRunProfileFormInput);

    // devices は「同じ集合なら並び順が違っても未変更」とみなす(マシンのデバイス順とプロファイル
    // の記載順は独立で、チェック操作をしていないのに dirty になるのを避けるため)。
    function runProfileDevicesEqual(a, b) {
      if (a.length !== b.length) {
        return false;
      }
      const setB = new Set(b);
      return a.every((name) => setB.has(name));
    }

    function runProfileValuesEqual(fields) {
      return (
        runProfileMachine.value === fields.machine &&
        runProfileApp.value === fields.app &&
        runProfileDevicesEqual(runProfileCheckedNames, fields.devices) &&
        runProfileHeal.checked === fields.heal &&
        runProfileReportDir.value === fields.reportDir &&
        runProfileDefaultTimeout.value === fields.defaultTimeout
      );
    }

    function onRunProfileFormInput() {
      if (runProfileOriginalFields === null || runProfileSubmitting) {
        return;
      }
      setRunProfileDirty(!runProfileValuesEqual(runProfileOriginalFields));
      // 入力を変えたら前回のエラー表示は古くなるので消す(editorError と同じ方針)。
      runProfileError.textContent = '';
    }

    function setRunProfileControlsEnabled(enabled) {
      runProfileMachine.disabled = !enabled;
      runProfileApp.disabled = !enabled;
      runProfileHeal.disabled = !enabled;
      runProfileReportDir.disabled = !enabled;
      runProfileDefaultTimeout.disabled = !enabled;
      for (const checkbox of runProfileDevices.querySelectorAll('input[type="checkbox"]')) {
        checkbox.disabled = !enabled;
      }
    }

    // クライアント検証(確定時)。問題なければ null。
    function validateRunProfileFields() {
      const machine = runProfileMachine.value.trim();
      if (machine === '') {
        return '使用するマシンプロファイルを指定してください。';
      }
      if (!findMachine(machine)) {
        return 'マシンプロファイル「' + machine + '」が見つかりません。';
      }
      if (runProfileApp.value.trim() === '') {
        return 'アプリを指定してください。';
      }
      if (runProfileCheckedNames.length === 0) {
        return 'デバイスを1台以上選択してください。';
      }
      const timeout = runProfileDefaultTimeout.value.trim();
      if (timeout !== '' && (!/^\\d+$/.test(timeout) || Number(timeout) <= 0)) {
        return 'defaultTimeout は正の整数で入力してください。';
      }
      return null;
    }

    runProfileConfirm.addEventListener('click', () => {
      if (runProfileConfirm.disabled || runProfileSubmitting || !selectedRunProfile) {
        return;
      }
      const validationError = validateRunProfileFields();
      if (validationError) {
        runProfileError.textContent = validationError;
        return;
      }
      runProfileSubmitting = true;
      setRunProfileControlsEnabled(false);
      runProfileConfirm.textContent = '確定中...';
      runProfileError.textContent = '';
      refreshRunProfileButtonsUi();
      vscode.postMessage({
        type: 'runProfileSave',
        profile: selectedRunProfile,
        fields: {
          machine: runProfileMachine.value.trim(),
          app: runProfileApp.value.trim(),
          devices: runProfileCheckedNames.slice(),
          heal: runProfileHeal.checked,
          reportDir: runProfileReportDir.value.trim(),
          defaultTimeout: runProfileDefaultTimeout.value.trim(),
        },
      });
    });

    // キャンセル: dirty/送信中フラグを先に解除してから runProfileLoad を再送する
    // (applyRunProfileData は runProfileEditing() の間は応答を無視するガードがあるため、
    // 先に解除しておかないと再ロード結果が反映されない)。requestRunProfileLoad は内部で
    // showRunProfilePlaceholder→setRunProfileDirty(false) を呼ぶため、この順序を満たす。
    runProfileCancel.addEventListener('click', () => {
      if (runProfileCancel.disabled) {
        return;
      }
      runProfileError.textContent = '';
      requestRunProfileLoad();
    });

    // runProfileSave の結果。ok なら dirty 解除(ホストが続けて runProfileData を送るので、
    // フォームはそこで最新値に作り直される)。ok:false ならエラー表示のみで入力値は残す。
    function applyRunProfileSaveResult(message) {
      if (message.profile !== selectedRunProfile) {
        return;
      }
      runProfileSubmitting = false;
      runProfileConfirm.textContent = '確定';
      setRunProfileControlsEnabled(true);
      if (message.ok) {
        runProfileError.textContent = '';
        setRunProfileDirty(false);
      } else {
        refreshRunProfileButtonsUi();
        runProfileError.textContent = message.error || '実行プロファイルの更新に失敗しました。';
      }
    }

    // runs/<name>.json の外部編集(watcher onDidChange)。編集対象と同名 && 未編集のときのみ
    // 再ロードして自動反映する(自分の保存直後の通知も来るが、その再ロードは冪等)。
    function applyRunProfileFileChanged(message) {
      if (message.name === selectedRunProfile && !runProfileEditing()) {
        vscode.postMessage({ type: 'runProfileLoad', profile: selectedRunProfile });
      }
    }

    // ---- デバイス追加モーダル ---------------------------------------------------

    // 複製元: src/monitorModel.ts の validateNewDeviceName。webview は CSP により import 不可のため
    // 複製する(deviceOpMenuItem の複製と同じ方針。ロジックを変更したら両方に反映すること)。
    function validateNewDeviceName(name, existing) {
      const trimmed = name.trim();
      if (trimmed.length === 0) {
        return 'デバイス名を入力してください。';
      }
      if (existing.includes(trimmed)) {
        return '「' + trimmed + '」は既に存在します。';
      }
      return null;
    }

    const deviceAddOverlay = document.getElementById('device-add-overlay');
    const dlgPlatformIos = document.getElementById('dlg-platform-ios');
    const dlgPlatformAndroid = document.getElementById('dlg-platform-android');
    const dlgModel = document.getElementById('dlg-model');
    const dlgOs = document.getElementById('dlg-os');
    const dlgName = document.getElementById('dlg-name');
    const dlgError = document.getElementById('dlg-error');
    const dlgCancel = document.getElementById('dlg-cancel');
    const dlgOk = document.getElementById('dlg-ok');

    let deviceAddOpen = false;
    let deviceAddCreating = false;
    // deviceCatalogRequest の応答(deviceCatalog.ok:true の catalog)。未着/失敗中は null。
    let deviceCatalog = null;
    // デバイス名をユーザーが手で編集したか(true の間は自動生成に追従しない)。
    let dlgNameDirty = false;
    // このモーダルを #device-pick-overlay の「+」(device-pick-add-new)から開いたか。
    // #device-pick-overlay はフルスクリーンのオーバーレイなので、openDeviceAddModal() 呼び出し時点の
    // devicePickOpen がそのまま「ピッカー経由かどうか」の判定になる(下の openDeviceAddModal 参照)。
    // true の間は createDevice に register:false を送り(物理作成のみ)、成功時は pendingAutoCheck を
    // 使って一覧再描画時に該当行をチェックONにする(2026-07-11 指示)。
    let deviceAddFromPicker = false;

    // OS種別はラジオボタン2つ(dlg-platform-ios/-android、name="dlg-platform")で1つの select 相当を
    // 表す。読み書きをここに集約し、他の場所は select だった頃と同じ感覚で扱えるようにする。
    function getDialogPlatform() {
      return dlgPlatformIos.checked ? 'ios' : 'android';
    }
    function setDialogPlatform(value) {
      dlgPlatformIos.checked = value === 'ios';
      dlgPlatformAndroid.checked = value === 'android';
    }

    function setDialogControlsEnabled(enabled) {
      dlgPlatformIos.disabled = !enabled;
      dlgPlatformAndroid.disabled = !enabled;
      dlgModel.disabled = !enabled;
      dlgOs.disabled = !enabled;
      dlgName.disabled = !enabled;
    }

    function fillSelect(select, options) {
      select.textContent = '';
      for (const opt of options) {
        const el = document.createElement('option');
        el.value = opt.value;
        el.textContent = opt.label;
        select.appendChild(el);
      }
    }

    function modelOptionsFor(platform) {
      if (!deviceCatalog) {
        return [];
      }
      return platform === 'ios'
        ? deviceCatalog.ios.deviceTypes.map((d) => ({ value: d.identifier, label: d.name }))
        : deviceCatalog.android.models.map((m) => ({ value: m.id, label: m.name }));
    }

    function osOptionsFor(platform) {
      if (!deviceCatalog) {
        return [];
      }
      if (platform === 'ios') {
        return deviceCatalog.ios.runtimes.map((r) => ({ value: r.identifier, label: r.name }));
      }
      return deviceCatalog.android.systemImages.map((s) => ({
        value: s.package,
        label: s.versionName + '(API ' + s.apiLevel + ') ' + s.tag + ' / ' + s.abi,
      }));
    }

    function selectedOptionLabel(select) {
      const opt = select.options[select.selectedIndex];
      return opt ? opt.textContent : '';
    }

    // iOS = "モデル名(ランタイム名)"、Android = "モデル名(versionName)"(モデル未選択なら空文字)。
    function autoDeviceName() {
      const modelLabel = selectedOptionLabel(dlgModel);
      if (!modelLabel) {
        return '';
      }
      const osLabel = selectedOptionLabel(dlgOs);
      return osLabel ? modelLabel + '(' + osLabel + ')' : modelLabel;
    }

    function refreshAutoName() {
      if (!dlgNameDirty) {
        dlgName.value = autoDeviceName();
      }
    }

    // カタログの available:false 側はラジオ自体を disabled にし、現在の選択がその側だった場合は
    // 利用可能な側へ寄せる(両方 available:false の場合は変更しない = OK 側で弾かれる想定)。
    // setDialogControlsEnabled(true) の直後にも呼び直すことで、いったん disabled にした
    // ラジオを一律 enabled に戻す際、available:false 側を誤って有効に戻さないようにする
    // (select だった頃は select 自体の disabled と option 個別の disabled が独立していたが、
    // ラジオは disabled が1階層しかないため、有効化のたびに可用性を再適用する必要がある)。
    function applyPlatformAvailability() {
      dlgPlatformIos.disabled = !deviceCatalog.ios.available;
      dlgPlatformAndroid.disabled = !deviceCatalog.android.available;
      if (getDialogPlatform() === 'ios' && !deviceCatalog.ios.available && deviceCatalog.android.available) {
        setDialogPlatform('android');
      } else if (getDialogPlatform() === 'android' && !deviceCatalog.android.available && deviceCatalog.ios.available) {
        setDialogPlatform('ios');
      }
    }

    function refreshModelAndOsOptions() {
      fillSelect(dlgModel, modelOptionsFor(getDialogPlatform()));
      fillSelect(dlgOs, osOptionsFor(getDialogPlatform()));
      refreshAutoName();
    }

    dlgPlatformIos.addEventListener('change', () => refreshModelAndOsOptions());
    dlgPlatformAndroid.addEventListener('change', () => refreshModelAndOsOptions());
    dlgModel.addEventListener('change', () => refreshAutoName());
    dlgOs.addEventListener('change', () => refreshAutoName());
    dlgName.addEventListener('input', () => {
      if (dlgName.value.trim().length === 0) {
        // 空にした = 自動生成への追従を再開する
        dlgNameDirty = false;
        dlgName.value = autoDeviceName();
      } else {
        dlgNameDirty = true;
      }
    });

    function openDeviceAddModal() {
      if (!selectedMachine) {
        return;
      }
      // devicePickOpen は #device-pick-overlay がフルスクリーンのオーバーレイであるため、
      // ここで呼ばれた時点の値がそのまま「ピッカーの「+」から開いたか」の判定になる
      // (btn-device-add はピッカー表示中はオーバーレイに隠れてクリックできない)。
      deviceAddFromPicker = devicePickOpen;
      deviceAddOpen = true;
      deviceAddCreating = false;
      deviceCatalog = null;
      dlgNameDirty = false;
      dlgName.value = '';
      dlgModel.textContent = '';
      dlgOs.textContent = '';
      dlgError.classList.add('info');
      dlgError.textContent = 'カタログを読み込み中...';
      setDialogControlsEnabled(false);
      dlgOk.disabled = true;
      dlgOk.textContent = 'OK';
      dlgCancel.disabled = false;
      deviceAddOverlay.classList.add('visible');
      vscode.postMessage({ type: 'deviceCatalogRequest' });
    }

    function closeDeviceAddModal() {
      if (!deviceAddOpen || deviceAddCreating) {
        return;
      }
      deviceAddOpen = false;
      deviceAddOverlay.classList.remove('visible');
    }

    function applyDeviceCatalog(message) {
      if (!deviceAddOpen) {
        return; // モーダルを閉じた後に届いた応答は無視する
      }
      if (!message.ok || !message.catalog) {
        dlgError.classList.remove('info');
        dlgError.textContent = message.error || 'カタログの取得に失敗しました。';
        dlgOk.disabled = true;
        return;
      }
      deviceCatalog = message.catalog;
      dlgError.classList.remove('info');
      dlgError.textContent = '';
      setDialogControlsEnabled(true);
      applyPlatformAvailability();
      refreshModelAndOsOptions();
      dlgOk.disabled = false;
    }

    function applyCreateDeviceResult(message) {
      if (!deviceAddOpen) {
        return;
      }
      deviceAddCreating = false;
      dlgCancel.disabled = false;
      dlgOk.textContent = 'OK';
      if (message.ok) {
        closeDeviceAddModal();
        // register:false(ピッカー経由)で作成できた場合、次の一覧再読込でその行を自動チェックONに
        // するための識別子を保持しておく(pendingAutoCheck。renderDevicePickGroups 参照)。
        if (deviceAddFromPicker) {
          pendingAutoCheck = message.device ? { udid: message.device.udid, avd: message.device.avd } : null;
        }
        reloadDevicePickIfOpen();
        return;
      }
      dlgOk.disabled = false;
      setDialogControlsEnabled(true);
      // setDialogControlsEnabled(true) は両ラジオを一律 enabled にするため、available:false 側を
      // 再度 disabled に戻す(applyPlatformAvailability 冒頭のコメント参照)。
      applyPlatformAvailability();
      dlgError.classList.remove('info');
      dlgError.textContent = message.error || 'デバイスの作成に失敗しました。';
    }

    // 「+新規作成」ボタンは廃止(2026-07-11 指示)。新規作成モーダル(openDeviceAddModal)は
    // 「+」で開く選択画面(#device-pick-overlay)内の「+」からのみ開く(=常に register:false 経路)。
    dlgCancel.addEventListener('click', () => closeDeviceAddModal());
    deviceAddOverlay.addEventListener('click', (event) => {
      if (event.target === deviceAddOverlay) {
        closeDeviceAddModal();
      }
    });
    dlgOk.addEventListener('click', () => {
      if (dlgOk.disabled || deviceAddCreating || !deviceCatalog) {
        return;
      }
      const name = dlgName.value.trim();
      const error = validateNewDeviceName(name, allDeviceNamesForSelectedMachine());
      if (error) {
        dlgError.classList.remove('info');
        dlgError.textContent = error;
        return;
      }
      deviceAddCreating = true;
      setDialogControlsEnabled(false);
      dlgOk.disabled = true;
      dlgCancel.disabled = true;
      dlgOk.textContent = '作成中...';
      dlgError.textContent = '';
      vscode.postMessage({
        type: 'createDevice',
        machine: selectedMachine,
        platform: getDialogPlatform(),
        name: name,
        model: dlgModel.value,
        os: dlgOs.value,
        // ピッカー経由(deviceAddFromPicker)なら物理作成のみ(register:false)。登録はピッカーの
        // OK(machineDevicesSync)で行う。.profile-actions の「+新規作成」から直接開いた場合は
        // 従来どおり即登録する。
        register: !deviceAddFromPicker,
      });
    });
    // 既存の Esc ハンドラ(closeDeviceOpMenu)とは別のリスナーとして追加する(closeDeviceAddModal
    // は自分の状態(deviceAddOpen/deviceAddCreating)だけを見るので、両者は独立して安全に共存する)。
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeDeviceAddModal();
      }
    });

    // ---- 名前入力モーダル(#name-input-overlay) ----------------------------------------
    // 実行/アプリ/マシンプロファイルの追加・コピー・名前変更(9箇所)を担う、showInputBox 相当の
    // 置き換え。拡張側の nameInputOpen で開き、OK/キャンセルは nameInputConfirm/nameInputCancel を
    // id 付きで返す(拡張側の pendingNameInput と突き合わせる)。検証ルールは拡張側の
    // validateNewRunProfileName/validateNewAppProfileName/validateNewMachineProfileName と同一
    // (空/"/""\""/"."始まり/重複)。renderHtml() の巨大テンプレートリテラル内でバックスラッシュ文字を
    // 直に書くと二重エスケープが必要になり事故りやすいため(#run-profile-devices-row 付近の \\d の
    // 教訓と同じ理由)、String.fromCharCode(92) で組み立てて回避する。

    const nameInputOverlay = document.getElementById('name-input-overlay');
    const nameInputTitleEl = document.getElementById('name-input-title');
    const nameInputField = document.getElementById('name-input-field');
    const nameInputErrorEl = document.getElementById('name-input-error');
    const nameInputCancelBtn = document.getElementById('name-input-cancel');
    const nameInputOkBtn = document.getElementById('name-input-ok');

    const NAME_INPUT_BACKSLASH = String.fromCharCode(92);

    // { id, noun, dupLabel, existing, caseInsensitiveDup, touched } | null
    let nameInputState = null;

    function validateNameInputValue(raw, state) {
      const trimmed = raw.trim();
      if (trimmed.length === 0) {
        return state.noun + 'を入力してください。';
      }
      if (trimmed.indexOf('/') !== -1 || trimmed.indexOf(NAME_INPUT_BACKSLASH) !== -1) {
        return state.noun + 'に "/" や "' + NAME_INPUT_BACKSLASH + '" は使えません。';
      }
      if (trimmed.charAt(0) === '.') {
        return state.noun + 'を "." で始めることはできません。';
      }
      const compareName = state.caseInsensitiveDup ? trimmed.toLowerCase() : trimmed;
      const isDup = state.existing.some((item) => (state.caseInsensitiveDup ? item.toLowerCase() : item) === compareName);
      if (isDup) {
        return state.dupLabel + '「' + trimmed + '」は既に存在します。';
      }
      return null;
    }

    // エラー文言の表示・OKボタンの disabled 状態を、現在の入力値で更新する。開いた直後の空欄に
    // いきなり「入力してください」を出さないよう、value が非空 or 一度でも入力があった(touched)
    // 場合のみエラー文言を表示する(disabled の切替自体は常に行う)。
    function refreshNameInputValidation() {
      if (!nameInputState) {
        return;
      }
      const raw = nameInputField.value;
      const error = validateNameInputValue(raw, nameInputState);
      const shouldShowError = raw.trim().length > 0 || nameInputState.touched;
      nameInputErrorEl.textContent = shouldShowError && error ? error : '';
      nameInputOkBtn.disabled = !!error;
    }

    function closeNameInputModal() {
      nameInputOverlay.classList.remove('visible');
      nameInputState = null;
    }

    function confirmNameInput() {
      if (!nameInputState || nameInputOkBtn.disabled) {
        return;
      }
      vscode.postMessage({ type: 'nameInputConfirm', id: nameInputState.id, name: nameInputField.value });
      closeNameInputModal();
    }

    function cancelNameInput() {
      if (!nameInputState) {
        return;
      }
      vscode.postMessage({ type: 'nameInputCancel', id: nameInputState.id });
      closeNameInputModal();
    }

    function applyNameInputOpen(message) {
      // 二重 nameInputOpen 受信時は単に上書き再初期化する(通常は起こらないが念のため)。
      nameInputState = {
        id: message.id,
        noun: message.noun,
        dupLabel: message.dupLabel,
        existing: message.existing,
        caseInsensitiveDup: message.caseInsensitiveDup,
        touched: false,
      };
      nameInputTitleEl.textContent = message.title;
      nameInputField.value = message.value;
      nameInputErrorEl.textContent = '';
      nameInputOverlay.classList.add('visible');
      nameInputField.focus();
      if (message.value.length > 0) {
        nameInputField.select();
      }
      refreshNameInputValidation();
    }

    nameInputField.addEventListener('input', () => {
      if (!nameInputState) {
        return;
      }
      nameInputState.touched = true;
      refreshNameInputValidation();
    });
    nameInputField.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        confirmNameInput();
      }
    });
    nameInputOkBtn.addEventListener('click', () => confirmNameInput());
    nameInputCancelBtn.addEventListener('click', () => cancelNameInput());
    nameInputOverlay.addEventListener('click', (event) => {
      if (event.target === nameInputOverlay) {
        cancelNameInput();
      }
    });
    // 名前入力モーダルは他のモーダル(デバイス追加/デバイス選択)と同時には開かないため、
    // device-add-overlay の Esc ハンドラ(上記)と同じ独立した専用リスナーとして追加する
    // (deviceAddOpen 等の他モーダルの状態は見なくてよい)。
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && nameInputState) {
        cancelNameInput();
      }
    });

    // ---- 「+既存から選択」モーダル(#device-pick-overlay。要件2) -----------------------
    // インストール済みの iOS シミュレータ/Android AVD を一覧表示する。チェックボックスは
    // 「選択」ではなく「マシンプロファイルへの登録状態そのもの」を表す(初期値=現在の登録有無)。
    // OK は行ごとの初期状態からの差分をまとめて machineDevicesSync(add/remove)で送る。
    // 実機で数十件規模になりうる前提(コーディネーター指示)。

    const devicePickOverlay = document.getElementById('device-pick-overlay');
    const devicePickIosTitle = document.getElementById('device-pick-ios-title');
    const devicePickIosBody = document.getElementById('device-pick-ios-body');
    const devicePickAndroidTitle = document.getElementById('device-pick-android-title');
    const devicePickAndroidBody = document.getElementById('device-pick-android-body');
    const devicePickError = document.getElementById('device-pick-error');
    const devicePickCancel = document.getElementById('device-pick-cancel');
    const devicePickOk = document.getElementById('device-pick-ok');
    const devicePickAddNewBtn = document.getElementById('device-pick-add-new');

    let devicePickOpen = false;
    let devicePickAdding = false;
    // 直近描画した行(チェックボックス+対応データ+初期状態)。チェックボックスは「選択」ではなく
    // 「登録状態そのもの」を表すので、initialChecked(=描画時点の登録有無)を保持しておき、OK
    // クリック時にそこからの差分(行ごとの checkbox.checked !== initialChecked)だけを
    // machineDevicesSync の add/remove として組み立てる。registeredName は登録済みだった行を
    // 未チェックにした場合の削除対象(マシンプロファイル上の name)。
    let devicePickIosRows = [];
    let devicePickAndroidRows = [];
    // register:false で新規作成した直後、次の installedDevices 再描画で自動チェックONにしたい行の
    // 識別子(iOS=udid/Android=avd の id)。作成に成功していない/一致する行が無い場合はどちらも
    // null のままでよい(applyPendingAutoCheck が静かに諦める)。適用後は必ず null に戻す
    // (一度きりの適用。2026-07-11 指示)。
    let pendingAutoCheck = null;

    // 選択中マシンの既存デバイスから、識別値→マシンプロファイル上の name への対応表を作る
    // (初期チェック状態の判定と、登録解除[remove]時にどの name を消せばよいかの両方に使う)。
    // iOS は udid 一致、Android は avd が id または displayName に一致するものを登録済みとみなす
    // (要件2)。
    function registeredIosNameByUdid() {
      const machine = findMachine(selectedMachine);
      const map = new Map();
      if (machine) {
        for (const d of machine.devices) {
          if (d.platform === 'ios' && d.udid) {
            map.set(d.udid, d.name);
          }
        }
      }
      return map;
    }
    function registeredAndroidNameByAvd() {
      const machine = findMachine(selectedMachine);
      const map = new Map();
      if (machine) {
        for (const d of machine.devices) {
          if (d.platform === 'android' && d.avd) {
            map.set(d.avd, d.name);
          }
        }
      }
      return map;
    }

    // OK は「行ごとの初期状態(登録有無)からの差分が1件以上ある」ときだけ有効にする
    // (チェックボックス=登録状態の設計上、単に何かがチェックされているかどうかでは判定できない)。
    function updateDevicePickOkState() {
      if (devicePickAdding) {
        return;
      }
      const anyDiff =
        devicePickIosRows.some((row) => row.checkbox.checked !== row.initialChecked) ||
        devicePickAndroidRows.some((row) => row.checkbox.checked !== row.initialChecked);
      devicePickOk.disabled = !anyDiff;
    }

    function buildDevicePickEmptyRow(container, text) {
      const empty = document.createElement('div');
      empty.className = 'device-pick-empty';
      empty.textContent = text;
      container.appendChild(empty);
    }

    // checked クラス(選択配色。CSS側 .device-pick-row.checked)を checkbox.checked に同期する。
    // checkbox.checked のプログラム的変更は change イベントを発火しないため、変更経路
    // (初期描画/行クリック/自動チェック)ごとに明示的に呼ぶ。
    function syncDevicePickRowChecked(row, checkbox) {
      row.classList.toggle('checked', checkbox.checked);
    }

    // 行のどこをクリックしてもチェックが切り替わるようにする(ユーザー指定)。チェックボックス
    // 自体のクリックはネイティブのトグルに任せる(row の click でも拾ってしまうと二重トグルで
    // 元に戻ってしまうため除外する)。適用中等で checkbox が disabled の間は何もしない。
    function attachDevicePickRowToggle(row, checkbox) {
      row.addEventListener('click', (event) => {
        if (event.target === checkbox || checkbox.disabled) {
          return;
        }
        checkbox.checked = !checkbox.checked;
        syncDevicePickRowChecked(row, checkbox);
        // プログラム的な .checked 変更は change イベントを発火しないため、明示的に更新する。
        updateDevicePickOkState();
      });
    }

    // installedDevices(InstalledDevices の形)から2グループ分の行を組み立てる。
    function renderDevicePickGroups(data) {
      devicePickIosRows = [];
      devicePickAndroidRows = [];
      devicePickIosBody.textContent = '';
      devicePickAndroidBody.textContent = '';

      const iosNameByUdid = registeredIosNameByUdid();
      const iosData = data.ios;
      devicePickIosTitle.textContent = 'iOS シミュレータ (' + iosData.devices.length + ')';
      if (!iosData.available) {
        buildDevicePickEmptyRow(devicePickIosBody, iosData.error || 'iOS シミュレータを取得できませんでした。');
      } else if (iosData.devices.length === 0) {
        buildDevicePickEmptyRow(devicePickIosBody, 'iOS シミュレータがありません。');
      } else {
        for (const device of iosData.devices) {
          const registeredName = iosNameByUdid.get(device.udid);
          const registered = registeredName !== undefined;
          const row = document.createElement('div');
          row.className = 'device-pick-row';
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.checked = registered;
          checkbox.addEventListener('change', () => {
            syncDevicePickRowChecked(row, checkbox);
            updateDevicePickOkState();
          });
          const textWrap = document.createElement('div');
          textWrap.className = 'device-pick-row-text';
          // タイル/レーン/マシンプロファイル一覧と同じ配色ピル(.tile-name/-ios)を共用する(要件2)。
          const nameEl = document.createElement('span');
          nameEl.className = 'device-pick-row-name tile-name tile-name-ios';
          nameEl.textContent = device.name;
          const detailEl = document.createElement('div');
          detailEl.className = 'device-pick-row-detail';
          detailEl.textContent = 'iOS ' + device.os + ' / ' + device.udid.slice(0, 8);
          textWrap.append(nameEl, detailEl);
          row.append(checkbox, textWrap);
          attachDevicePickRowToggle(row, checkbox);
          syncDevicePickRowChecked(row, checkbox);
          devicePickIosBody.appendChild(row);
          devicePickIosRows.push({ checkbox: checkbox, device: device, initialChecked: registered, registeredName: registeredName, rowEl: row });
        }
      }

      const androidNameByAvd = registeredAndroidNameByAvd();
      const androidData = data.android;
      devicePickAndroidTitle.textContent = 'Android AVD (' + androidData.avds.length + ')';
      if (!androidData.available) {
        buildDevicePickEmptyRow(devicePickAndroidBody, androidData.error || 'Android AVD を取得できませんでした。');
      } else if (androidData.avds.length === 0) {
        buildDevicePickEmptyRow(devicePickAndroidBody, 'Android AVD がありません。');
      } else {
        for (const avd of androidData.avds) {
          const registeredName = androidNameByAvd.get(avd.id) ?? androidNameByAvd.get(avd.displayName);
          const registered = registeredName !== undefined;
          const row = document.createElement('div');
          row.className = 'device-pick-row';
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.checked = registered;
          checkbox.addEventListener('change', () => {
            syncDevicePickRowChecked(row, checkbox);
            updateDevicePickOkState();
          });
          const textWrap = document.createElement('div');
          textWrap.className = 'device-pick-row-text';
          // タイル/レーン/マシンプロファイル一覧と同じ配色ピル(.tile-name/-android)を共用する(要件2)。
          const nameEl = document.createElement('span');
          nameEl.className = 'device-pick-row-name tile-name tile-name-android';
          nameEl.textContent = avd.displayName;
          const detailEl = document.createElement('div');
          detailEl.className = 'device-pick-row-detail';
          const detailParts = [];
          if (avd.id !== avd.displayName) {
            detailParts.push(avd.id);
          }
          detailEl.textContent = detailParts.join('・');
          textWrap.append(nameEl, detailEl);
          row.append(checkbox, textWrap);
          attachDevicePickRowToggle(row, checkbox);
          syncDevicePickRowChecked(row, checkbox);
          devicePickAndroidBody.appendChild(row);
          devicePickAndroidRows.push({ checkbox: checkbox, avd: avd, initialChecked: registered, registeredName: registeredName, rowEl: row });
        }
      }
    }

    // pendingAutoCheck(register:false で新規作成した直後の識別子)が指す行があれば、その行の
    // チェックボックスだけを ON にする(initialChecked は renderDevicePickGroups が判定した
    // 「登録済みかどうか」のまま false なので、ここで checked を true にすれば差分[ユーザー操作扱い]
    // として OK ボタンが有効になる)。一致する行が無ければ何もしない(静かに諦める。2026-07-11 指示)。
    // renderDevicePickGroups の直後(devicePickIosRows/devicePickAndroidRows が最新化された後)に
    // 呼ぶこと。呼んだら pendingAutoCheck は必ずクリアする(一度きりの適用)。
    function applyPendingAutoCheck() {
      if (!pendingAutoCheck) {
        return;
      }
      const target = pendingAutoCheck;
      pendingAutoCheck = null;
      if (target.udid) {
        const row = devicePickIosRows.find((r) => r.device.udid === target.udid);
        if (row) {
          row.checkbox.checked = true;
          syncDevicePickRowChecked(row.rowEl, row.checkbox);
        }
      }
      if (target.avd) {
        const row = devicePickAndroidRows.find((r) => r.avd.id === target.avd);
        if (row) {
          row.checkbox.checked = true;
          syncDevicePickRowChecked(row.rowEl, row.checkbox);
        }
      }
    }

    // 同期リクエスト送信中(devicePickAdding)はチェックボックスも含めて全コントロールを disabled
    // にする。チェックボックスは「登録状態そのもの」で常に操作可能な設計になったため、再度
    // 有効化する際も一律 enabled に戻せばよい(以前のような「登録済み行だけ disabled のまま戻す」
    // 例外はもう無い)。
    function setDevicePickControlsEnabled(enabled) {
      for (const row of devicePickIosRows.concat(devicePickAndroidRows)) {
        row.checkbox.disabled = !enabled;
      }
    }

    // #device-add-overlay(「+新規作成」)での作成が成功した後、このモーダルがまだ開いていれば
    // 一覧を再取得して作り直す。全行が installedDevicesRequest の新しい応答から再描画されるため、
    // 登録状態は最新値に自然と揃う(=他行の未確定の差分は破棄される。単純さを優先した設計判断)。
    function reloadDevicePickIfOpen() {
      if (!devicePickOpen) {
        return;
      }
      devicePickError.classList.add('info');
      devicePickError.textContent = '一覧を読み込み中...';
      devicePickOk.disabled = true;
      vscode.postMessage({ type: 'installedDevicesRequest' });
    }

    function openDevicePickModal() {
      if (!selectedMachine) {
        return;
      }
      devicePickOpen = true;
      devicePickAdding = false;
      pendingAutoCheck = null; // 前回開いた際の残留分があれば捨てて、新規セッションはクリーンに始める
      devicePickIosRows = [];
      devicePickAndroidRows = [];
      devicePickIosBody.textContent = '';
      devicePickAndroidBody.textContent = '';
      devicePickIosTitle.textContent = 'iOS シミュレータ';
      devicePickAndroidTitle.textContent = 'Android AVD';
      devicePickError.classList.add('info');
      devicePickError.textContent = '一覧を読み込み中...';
      devicePickOk.disabled = true;
      devicePickOk.textContent = 'OK';
      devicePickCancel.disabled = false;
      devicePickOverlay.classList.add('visible');
      vscode.postMessage({ type: 'installedDevicesRequest' });
    }

    function closeDevicePickModal() {
      if (!devicePickOpen || devicePickAdding) {
        return;
      }
      devicePickOpen = false;
      pendingAutoCheck = null; // 閉じた後に届く installedDevices 応答で誤適用しないようクリアする
      devicePickOverlay.classList.remove('visible');
    }

    function applyInstalledDevices(message) {
      if (!devicePickOpen) {
        return; // モーダルを閉じた後に届いた応答は無視する(applyDeviceCatalog と同じ方針)
      }
      if (!message.ok || !message.data) {
        devicePickError.classList.remove('info');
        devicePickError.textContent = message.error || '一覧の取得に失敗しました。';
        devicePickOk.disabled = true;
        return;
      }
      devicePickError.classList.remove('info');
      devicePickError.textContent = '';
      renderDevicePickGroups(message.data);
      applyPendingAutoCheck();
      updateDevicePickOkState();
    }

    function applyMachineDevicesSyncResult(message) {
      if (!devicePickOpen) {
        return;
      }
      devicePickAdding = false;
      devicePickCancel.disabled = false;
      devicePickOk.textContent = 'OK';
      if (message.ok) {
        closeDevicePickModal();
        return;
      }
      setDevicePickControlsEnabled(true);
      updateDevicePickOkState();
      devicePickError.classList.remove('info');
      devicePickError.textContent = message.error || 'デバイスの同期に失敗しました。';
    }

    btnDeviceAddExisting.addEventListener('click', () => openDevicePickModal());
    devicePickAddNewBtn.addEventListener('click', () => openDeviceAddModal());
    devicePickCancel.addEventListener('click', () => closeDevicePickModal());
    devicePickOverlay.addEventListener('click', (event) => {
      if (event.target === devicePickOverlay) {
        closeDevicePickModal();
      }
    });
    devicePickOk.addEventListener('click', () => {
      if (devicePickOk.disabled || devicePickAdding) {
        return;
      }
      const add = [];
      const remove = [];
      for (const row of devicePickIosRows) {
        if (row.checkbox.checked && !row.initialChecked) {
          add.push({
            platform: 'ios',
            name: row.device.name,
            simulator: row.device.name,
            os: row.device.os,
            udid: row.device.udid,
          });
        } else if (!row.checkbox.checked && row.initialChecked) {
          remove.push(row.registeredName);
        }
      }
      for (const row of devicePickAndroidRows) {
        if (row.checkbox.checked && !row.initialChecked) {
          add.push({ platform: 'android', name: row.avd.displayName, avd: row.avd.id });
        } else if (!row.checkbox.checked && row.initialChecked) {
          remove.push(row.registeredName);
        }
      }
      if (add.length === 0 && remove.length === 0) {
        return; // OK は差分がある間だけ有効なので通常ここには来ない(防御的ガード)
      }
      devicePickAdding = true;
      setDevicePickControlsEnabled(false);
      devicePickOk.disabled = true;
      devicePickCancel.disabled = true;
      devicePickOk.textContent = '適用中...';
      devicePickError.classList.remove('info');
      devicePickError.textContent = '';
      vscode.postMessage({ type: 'machineDevicesSync', machine: selectedMachine, add: add, remove: remove });
    });
    // 既存の Esc ハンドラとは別のリスナーとして追加する(closeDeviceAddModal の Esc ハンドラと
    // 同じ方針。closeDevicePickModal は自分の状態[devicePickOpen/devicePickAdding]だけを見るので
    // 独立して安全に共存する)。ただし今回から「+」ボタンでこのモーダルの上に #device-add-overlay を
    // 重ねて開けるようになったため、その間は Esc で奥のこのモーダルまで一緒に閉じないよう
    // deviceAddOpen を先にチェックする(手前の device-add-overlay 自身の Esc ハンドラは
    // deviceAddOpen だけを見るので、そちらは今まで通り自分自身を閉じる)。
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        if (deviceAddOpen) {
          return;
        }
        closeDevicePickModal();
      }
    });

    // ---- タブ切り替え(デバイス/プロファイル/設定) -----------------------------
    // 「設定」タブは現状プレースホルダーのみ(将来の機能追加先)。ここは
    // closeDeviceOpMenu・closeMachineDeviceMenu・applyTilePaneHeight・tilePaneHeight・
    // persistedState のいずれもが既に定義済みであることに依存するため、
    // スクリプトの最後(呼び出し側)にまとめて置く(関数宣言のホイスティングにより、
    // ソース上の定義順に関わらず参照できる)。

    const TAB_IDS = ['devices', 'profiles', 'settings'];
    const tabButtons = {
      devices: document.getElementById('tab-devices'),
      profiles: document.getElementById('tab-profiles'),
      settings: document.getElementById('tab-settings'),
    };
    const tabPanels = {
      devices: devicesPanel,
      profiles: document.getElementById('panel-profiles'),
      settings: document.getElementById('panel-settings'),
    };

    function persistActiveTab(tab) {
      vscode.setState(Object.assign({}, vscode.getState(), { activeTab: tab }));
    }

    function switchTab(tab) {
      // タブ切替中に前のタブで開いていた右クリックメニューを残さない。
      closeDeviceOpMenu();
      closeMachineDeviceMenu();
      for (const id of TAB_IDS) {
        const isActive = id === tab;
        tabButtons[id].classList.toggle('active', isActive);
        tabButtons[id].setAttribute('aria-selected', String(isActive));
        tabPanels[id].style.display = isActive ? 'flex' : 'none';
      }
      if (tab === 'devices') {
        // 非表示だった間 devicesPanel.clientHeight が 0 になり、applyTilePaneHeight が
        // ガードで何もせず抜けていた(誤クランプ防止)。再表示直後に呼び直して再クランプ+
        // relayoutTiles() する(applyTilePaneHeight が内部で relayoutTiles() まで行う)。
        applyTilePaneHeight(tilePaneHeight);
      }
    }

    for (const id of TAB_IDS) {
      tabButtons[id].addEventListener('click', () => {
        if (tabButtons[id].classList.contains('active')) {
          return;
        }
        switchTab(id);
        persistActiveTab(id);
      });
    }

    // プロファイルタブ先頭の sticky ジャンプヘッダー(#profile-jump-header)から各セクションへ
    // スクロールする(data-target=セクションの id)。scroll-margin-top(.profile-section)で
    // sticky ヘッダーの裏に見出しが隠れないようにしてある。
    for (const link of document.querySelectorAll('.profile-jump-link')) {
      link.addEventListener('click', () => {
        const target = document.getElementById(link.dataset.target);
        if (target) {
          target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      });
    }

    // 選択タブの永続化(vscode.getState())から復元する。不正値・未設定は 'devices'。
    const initialTab = TAB_IDS.includes(persistedState.activeTab) ? persistedState.activeTab : 'devices';
    switchTab(initialTab);

    updateLaneVisibility();
    updateLanesPlaceholder();

    // 初期化完了(全リスナー登録済み)を拡張側へ通知する(ready ハンドシェイク)。
    // 拡張側はこれを受けて初期状態(laneHydrate/profileInfo等)を送る。
    vscode.postMessage({ type: 'ready' });
  })();
  </script>
</body>
</html>`;
}
