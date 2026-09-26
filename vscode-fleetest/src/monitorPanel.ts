// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `fleetest.showDeviceMonitor`)。「ライブ操作」タブ
// (旧・独立パネル)は liveTabHost.ts の LiveTabHost がサブコントローラとして同居する。
// MonitorPanelController は以下のサブコントローラを束ねるオーケストレーターで、各サブコントローラは
// 互いを直接参照せず MonitorPanelDeps 経由でのみ連携する:
// - liveTabHost.ts の LiveTabHost: 「ライブ操作」タブのロジック(MonitorLiveController への窓口)。
//   fleetest.showLiveControl コマンド・デバイスタイル右クリック「ライブ操作」・
//   run 開始時の自動追従(fleetest.liveControlOnRun)から呼ばれる
// - monitorProcessManager.ts の MonitorProcessManager: monitor/host-metrics 常駐子プロセスの起動・停止・再起動
// - monitorProfilesController.ts の MonitorProfilesController: 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存
// - monitorDeviceOps.ts の MonitorDeviceOps: デバイスライフサイクルキュー・device-catalog/installed-devices/create-device
// - monitorDeviceStreamController.ts の MonitorDeviceStreamController: デバイスタイルの画面ストリーミング
//   (iOS/Android共通の StreamPipeline)管理。connected な monitorFrame ポーリングとの間引き調停は
//   MonitorProcessManager 側。
// - monitorDashboardController.ts の MonitorDashboardController: 「ダッシュボード」タブ(旧・単独
//   パネル dashboardPanel.ts)。`fleetest api results`/`results-run` のワンショット spawn と描画データの
//   配信。webview⇔host は "dashboard" 型の封筒({type:"dashboard", message: ...})で包んで送る
//   (モニター既存の ready/refresh 等と衝突するため。dashboardModel.ts の
//   DashboardFromWebviewMessage/DashboardToWebviewMessage 自体は不変)。
// - monitorHtml.ts: webview の HTML 本文(renderHtml/generateNonce/PANEL_TITLE)
// - monitorModel.ts / runLaneModel.ts / liveModel.ts: vscode 非依存の純粋関数(検証・変換・状態遷移)
//
// 契約・不変条件:
// - monitor プロセス、および devicesUp/devicesDown・device-catalog 等の短命 CLI 呼び出しは
//   cli.ts の FleetestCli(直列キュー)を使わず直接 spawn する。monitor は接続中ずっと動くプロセスなので、
//   キューに載せると以後の CLI 呼び出しが永久にブロックされるため。
// - 子プロセス終了は SIGTERM→2秒後もまだ生きていれば SIGKILL。monitor/host-metrics は
//   後始末(dispatch.lock 解放・終了スクリプト)を持たないヘルパーなのでこれでよい ——
//   `api run` 等の後始末を持つ子は既定で SIGKILL しない(cli.ts の cancelCurrent() 参照)。
// - ログレーン用の RunEventBus は runHandler.ts の実行と同一インスタンス(extension.ts から注入)。
//   デバイスタイルとログレーンは device id / worker id が同一規則のため突合できる。
// - host-metrics プロセスはプロファイル/プロジェクトに依存しないため、監視対象切り替え
//   (restartMonitorIfScopeChanged 等)では再起動しない。

import { type ChildProcessByStdio, execFile, spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import type { Readable } from "node:stream";
import * as vscode from "vscode";
import { repairDisplay, repairWifi } from "./adbWifiRepair";
import { childEnv } from "./childEnv";
import type { FleetestCli } from "./cli";
import { type FleetestConfig, resolveAdb, resolveProjectName } from "./config";
import { currentLocale, t } from "./i18n";
import {
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  disabledMachineSet,
  type MonitorDevice,
  type MonitorToWebviewMessage,
  type PlatformFilter,
  isPlatformFilter,
} from "./monitorModel";
import { type MachineLock, bulkDownGate, streamFoldMachines } from "./machineLockModel";
import { MonitorBridgeWatchdog } from "./monitorBridgeWatchdog";
import { MonitorDashboardController } from "./monitorDashboardController";
import { MonitorDeviceOps } from "./monitorDeviceOps";
import { MonitorDeviceStreamController } from "./monitorDeviceStreamController";
import { MonitorHealthWatchdog } from "./monitorHealthWatchdog";
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
import { LiveTabHost } from "./liveTabHost";
import type { LiveRunTarget } from "./liveRunTarget";
import { MonitorRecordingsController } from "./monitorRecordingsController";
import { workspaceRecordingsSessionsCache } from "./recordingsSessionsCache";
import { MonitorUpdateController } from "./monitorUpdateController";
import {
  fetchRemoteHosts,
  importRemoteHosts,
  removeRemoteHost,
  type RemoteHostsCliDeps,
  type RemoteHostsCliOutcome,
} from "./remoteHostsController";
import { diffRemoteHostsForSync, mergeRemoteHostsSideFields,
  type LocalMachineEntry, type MachineColor, type RemoteHostEntry } from "./remoteRunArgs";
import {
  fetchRetention,
  fetchRetentionUsage,
  type RetentionCliDeps,
  runCleanup,
  updateRetention,
} from "./retentionController";
import { formatBytesAuto, type RetentionPatch } from "./retentionModel";
import {
  TYPE_ORDER,
  parseAndroidBridges,
  parseResidentProcesses,
  planResidentKill,
  type ResidentProcess,
} from "./residentProcesses";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  isAnyLaneRunning,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";
import type { FleetestTestTree } from "./testTree";

const VIEW_TYPE = "fleetestMonitor";

type WipeStatusMessage = Extract<MonitorToWebviewMessage, { readonly type: "wipeStatus" }>;

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(monitorDeviceOps.ts の PipeProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** サブコントローラ間連携の唯一の窓口(サブコントローラ同士は互いを直接参照しない)。 */
export interface MonitorPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage): void;
  /** パネル表示中か。MonitorProcessManager.scheduleHostMetricsRestart()の5秒後再起動タイマーが使う。 */
  isPanelActive(): boolean;
  /** MonitorProcessManager.writeMonitorControlへの委譲。MonitorDeviceOpsのdown系ジョブ前後で呼ぶ。 */
  writeMonitorControl(cmd: MonitorControlCommand): void;
  /** MonitorDeviceStreamController.isStreamingへの委譲。monitorProcessManager.tsがmonitorFrameを
   * タイルへ転送する前にストリーミング中かどうか判定し、真なら間引く。 */
  isDeviceStreaming(deviceId: string): boolean;
  /** MonitorDeviceStreamController.streamingIdsへの委譲。monitor プロセス(再)起動直後の
   * suppressFrames 再送に使う(monitorProcessManager.ts 参照)。 */
  getStreamingDeviceIds(): readonly string[];
  /** monitorDevicesイベントをMonitorDeviceStreamControllerへ渡す(パイプラインの張り替え判定に使う。
   * monitorProcessManager.tsのmonitorDevices処理から呼ぶ)。 */
  notifyMonitorDevices(devices: readonly MonitorDevice[]): void;
  /** 機械の占有(dispatch.lock)が変わったときに MonitorProcessManager が呼ぶ。
   * **手元も含む**(キーは runBoardModel の LOCAL_MACHINE_KEY)。**配信の自動退避**
   * (占有中の機械のライブ配信を畳んでポーリングへ落とす)の入口
   * (docs/remote-runner.md §18.7 M2)。 */
  notifyMachineLocks(locks: ReadonlyMap<string, MachineLock>): void;
  /** その機械で run が走っているか(MonitorProcessManager.machineLock への委譲)。
   * **undefined は「不明」**(観測していない・旧ランナー)で、「走っていない」ではない。 */
  machineLock(machine: string): MachineLock | undefined;
  /** 設定タブの「ポーリングモードを使用する」チェックボックスの現在値。true の間は
   * monitorDeviceStreamController.ts がストリーミング開始を抑止しポーリングへフォールバックする
   * (workspaceState の "monitor.pollingMode" を共有する liveTabHost.ts/monitorLiveController.ts も同様)。 */
  isPollingMode(): boolean;
  /** 「デバイスモニター」タブの「ライブ更新」チェックボックス(workspaceState の
   * "monitor.showStreamDuringRun"。既定 ON)。false の間だけ run 中の台の配信を畳む。 */
  isShowStreamDuringRun(): boolean;
  /** MonitorProfilesController.postProfileInfoへの委譲。MonitorDeviceOps.runCreateDevice成功時に呼ぶ。 */
  notifyProjectDeviceCatalogChanged(): void;
  /** MonitorProcessManager.restartMonitorProcessへの委譲(パネル未生成時は no-op)。
   * MonitorProfilesController が監視対象ファイル(選択中の runs/<profile>.json。未選択時は
   * 全実行プロファイル)の変化で呼ぶ。 */
  restartMonitor(): void;
  /** MonitorProfilesController.unregisterDeletedDeviceへの委譲。実体を消したあと、その実体を
   * 参照している実行プロファイルから登録も外す(delete-device 成功時)。書き換えた実行プロファイル
   * 名を返す。 */
  unregisterDeletedDevice(
    platform: "ios" | "android",
    name: string,
    machine: string | undefined,
  ): { readonly runs: readonly string[] };
  /** MonitorDeviceStreamController.disposeForDeviceNameへの委譲。MonitorDeviceOpsのstop-deviceジョブが
   * 実行を開始する時点(simctl/adbで実際に殺す前)で呼び、タイルを即座に切断表示へ倒す。 */
  stopDeviceStreams(name: string, machine?: string): void;
  /** MonitorDeviceStreamController.disposeAllForDownへの委譲。MonitorDeviceOpsの一括downジョブの
   * 実行開始時に呼ぶ(stopDeviceStreamsの全台版)。 */
  stopAllStreams(): void;
  /** 生成したソース(絶対パス)を、デバイスモニターの列を避けた列に開く(モニター表示を覆わないため)。 */
  openGeneratedDocument(filePath: string): void;
  /** 録画動画ファイル(絶対パス)を webview から読める URI 文字列に変換する(録画タブ用)。
   * パネル未生成時は null。localResourceRoots(TestProjects/ 配下)の対象外パスを渡さないこと。 */
  videoWebviewUri(absPath: string): string | null;
  /** `fleetest <args>` を CLI キュー経由で実行する(Package.swift を書き換える project 系は
   *  list-scenarios のビルドと同時に走らせない)。出力は出力パネルへ流し、末尾を返す。 */
  runFleetestCli(args: readonly string[]): Promise<{ readonly ok: boolean; readonly output: string }>;
  /** 保存先を選ばせる(録画タブのエクスポート専用)。defaultAbsPath は既定のファイル名込み絶対パス、
   *  filterLabel はファイルの種類欄の表示名(拡張子は xlsx 固定)。キャンセル時は undefined。 */
  showSaveDialog(defaultAbsPath: string, filterLabel: string): Promise<string | undefined>;
  /** 情報メッセージ(actionLabel 省略でボタン無し)。押された結果のラベルを返す(押されなければ undefined)。 */
  showInfo(message: string, actionLabel?: string): Promise<string | undefined>;
  showError(message: string): void;
  /** OS の既定アプリでファイルを開く(vscode.env.openExternal)。 */
  openExternal(absPath: string): void;
}

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FleetestConfig,
  outputChannel: vscode.OutputChannel,
  cli: FleetestCli,
  testTree: FleetestTestTree,
  eventBus: RunEventBus,
): {
  relocalize(): void;
  prepareForRun(platform: "ios" | "android"): Promise<LiveRunTarget | undefined>;
} {
  const controller = new MonitorPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    cli,
    testTree,
    eventBus,
    context.extensionUri,
    context.workspaceState,
  );
  // TEST EXPLORER タイトルの view/title ボタンはペイン非フォーカス時に隠れる。
  // フォーカスに依存しない常時表示の導線としてステータスバーへ常駐させる。
  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  statusItem.text = t("monitor.statusBar.label");
  statusItem.tooltip = t("monitor.statusBar.tooltip");
  statusItem.command = "fleetest.showDeviceMonitor";
  statusItem.show();

  context.subscriptions.push(
    controller,
    statusItem,
    // 引数のタブ名は更新通知(updateCheck.ts)が "settings" を渡す。省略時は現在のタブのまま。
    vscode.commands.registerCommand("fleetest.showDeviceMonitor", (tab?: string) => controller.show(tab)),
    // 旧・単独パネル "結果ダッシュボード" は撤去済み(モニターのタブへ統合)。このコマンドは
    // モニターパネルを開いてダッシュボードタブを選択する動きに変える。
    vscode.commands.registerCommand("fleetest.showResultsDashboard", () => controller.show("dashboard")),
    vscode.commands.registerCommand("fleetest.showLiveControl", () => controller.showLiveControl()),
  );

  return {
    relocalize: () => controller.relocalize(),
    prepareForRun: (platform) => controller.prepareForRun(platform),
  };
}

/** export はテスト(panelRelocalize.test.mjs)が relocalize() を直接検証するため。
 * 生成経路は registerMonitorPanel のみ(シングルトン方針は変えない)。 */
export class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: MonitorPanelDeps;
  private readonly processManager: MonitorProcessManager;
  private readonly profiles: MonitorProfilesController;
  private readonly deviceOps: MonitorDeviceOps;
  private readonly bridgeWatchdog: MonitorBridgeWatchdog;
  private readonly healthWatchdog: MonitorHealthWatchdog;
  private readonly deviceStream: MonitorDeviceStreamController;
  private readonly recordings: MonitorRecordingsController;
  private readonly update: MonitorUpdateController;
  private readonly dashboard: MonitorDashboardController;
  private readonly live: LiveTabHost;

  /** パネル再作成時にhydrateLaneUi()で流し込むため、実行を跨いで保持する。 */
  private readonly laneState = createRunLaneState();
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;
  private readonly configChangeSubscription: vscode.Disposable;
  /** show(tab) が新規作成時に指定したタブ。sendInitialState() で switchTab を post した後クリアする
   * (html設定直後の postMessage は webview 側リスナー登録前に届き握りつぶされるため。show() 参照)。 */
  private pendingInitialTab: string | undefined;
  /** WebviewPanel.visible(他エディタタブの裏に隠れていないか)。 */
  private panelVisible = true;
  /** モニター内タブが「デバイスモニター」か(デバイスタイルが display:none でないか)。
   * webview から devicesTabVisible で届く。初期値 true は起動直後の一瞬だけで、
   * webview の初期 switchTab が必ず正しい値を送ってくる。 */
  private devicesTabVisible = true;
  /** 登録簿を1度でも CLI から読めたか。読む前の空の控えを「無効な機械は無い」と読まない */
  private remoteHostsLoaded = false;

  /** 配信helperを動かすのはパネルが見えていて かつ 「デバイスモニター」タブが開いていて かつ
   * 「ライブ更新」が ON のときだけ。どれか1つでも欠けると画面の配信・取り込み(suppressFrames)を全台止める
   * (見えない絵のエンコード/デコードは丸ごと無駄。OFF は利用者がマシンの負荷を下げる口。観測は monitor が続ける) */
  private applyDeviceStreamVisibility(): void {
    this.deviceStream.setVisible(this.panelVisible && this.devicesTabVisible && this.showStreamDuringRun);
  }
  /** 設定タブ「ポーリングモードを使用する」の現在値(ワークスペース単位で永続化)。 */
  private pollingMode: boolean;
  /** 「デバイスモニター」タブのスプリッター位置(タイルペイン高さ px)。未設定(パネル未ドラッグ)は undefined。
   * webview の getState はパネルを閉じると失われるため host 側で永続化する(splitter.js と対の契約)。 */
  private tilePaneHeight: number | undefined;
  private fleetVisible: boolean;
  /** 実行ログビュー(#log-pane)の高さ(px)。tilePaneHeight と同じ契約(splitter.js と対)。 */
  private logPaneHeight: number | undefined;
  /** プラットフォームの表示フィルタ。tilePaneHeight と同じ契約(deviceTiles.js と対)。
   * 既定は "all"(webview 側の既定と揃える。片方だけ変えない)。 */
  private platformFilter: PlatformFilter;
  /** run ボード(#run-board)の高さ(px)。tilePaneHeight と同じ契約(splitter.js と対)。
   * 未設定(セパレーター未ドラッグ)は undefined = 中身なりの高さ。 */
  private runBoardHeight: number | undefined;
  /** 実行ログビュー・グリッドビューの開閉。fleetVisible と同じ契約(splitter.js と対)。 */
  private logViewVisible: boolean;
  private gridViewVisible: boolean;
  /** run ボード(docs/design.md §18)の折りたたみ(workspaceState の "monitor.runBoardCollapsed")。
   * ヘッダの ▸/▾(個々の run 行の展開)は webview 側だけで持つ(runBoard.js。ephemeral な groupKey
   * ごとの状態はセッションを跨いで意味を持たない)。 */
  private runBoardCollapsed: boolean;
  /** run ボードの「全て展開」トグル(workspaceState の "monitor.runBoardExpandAll")。
   * **モードであって一度きりの操作ではない** —— ON の間は新しく現れた run も展開する
   * (だから groupKey ごとの展開と違い、セッションを跨いで意味を持つ = host が持つ)。 */
  private runBoardExpandAll: boolean;
  /** 「デバイスモニター」タブの全選択トグル(workspaceState の "monitor.selectAllDevices")。 */
  private selectAllDevices: boolean;
  private showStreamDuringRun: boolean;
  /** 直近の占有の控え。チェックボックスの切替で配信を畳む機械を引き直すのに使う。 */
  private lastMachineLocks: ReadonlyMap<string, MachineLock> = new Map();
  /** stopping/rebooting を post 済みで done/failed が未着のデバイス名。runEnded 時、キャンセル等で
   * done/failed が来ないまま残った名前にバッジ固着を防ぐため phase:"done" を post する。 */
  private readonly wipeInProgress = new Set<string>();
  /** ツールバーの「実行中」表示(= 「テストを中断」)。runStarted〜runEnded に加え、「テストを実行」を
   * 押してから run が始まるまで(startTestRunAfterDevicesUp)も true。 */
  private testRunActive = false;
  /** RunEventBus の runStarted〜runEnded の間だけ true(= 本当に run が走っている)。testRunActive を
   * 戻す判定の正本 —— 押下で立てた testRunActive は、run が始まらなければ runEnded が来ず戻らない。 */
  private busRunActive = false;
  /** 「録画を編集中」表示。recordingFinalizing(テストが全部終わり録画の切り出しだけが残った)から、
   * run の終了後に録画タブへの自動表示(revealRun)を片付けるまで true。webview 再読込でも復元する。 */
  private recordingsFinalizing = false;
  /** 「テストを実行」を押してから run を投げるまでの間(= 一括起動の完了待ち)。
   * この間の「テストを中断」は run ではなく一括起動を止める(startTestRunAfterDevicesUp)。 */
  private pendingRunStart = false;
  private runStartAborted = false;
  /** 直近に CLI(`fleetest api remote-machines`)から取得・同期した登録簿。setRemoteConfig の
   * 差分計算(diffRemoteHostsForSync)の基準に使うだけで、これ自体が正ではない
   * (docs/remote-runner.md §13「原則」。正は CLI の LocalConfig)。 */
  private lastKnownRemoteHosts: RemoteHostEntry[] = [];
  /** 未設定時の FM 枠(CLI が返す既定)。**拡張は値を持たず、読めたものをそのまま配る** */
  private lastKnownDefaultFMConcurrency: number | undefined;
  private lastKnownLocalMachine: LocalMachineEntry | undefined;
  /** バッジ色パレット(CLI 側の唯一の定義元)。**拡張は色の一覧を持たず、読めたものをそのまま配る**。
   *  古い CLI では undefined のまま(webview 側が色機能を黙って無効にする)。 */
  private lastKnownMachineColors: readonly MachineColor[] | undefined;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FleetestConfig,
    private readonly outputChannel: vscode.OutputChannel,
    private readonly cli: FleetestCli,
    testTree: FleetestTestTree,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
    private readonly workspaceState: vscode.Memento,
  ) {
    this.pollingMode = workspaceState.get<boolean>("monitor.pollingMode", false);
    this.tilePaneHeight = workspaceState.get<number>("monitor.tilePaneHeight");
    // 既定 ON(webview 側 splitter.js の「!== false」と揃える。片方だけ変えない)。
    // 既定 true(webview 側 splitter.js の「!== false」と揃える。片方だけ変えない)。
    this.fleetVisible = workspaceState.get<boolean>("monitor.fleetVisible", true);
    this.logPaneHeight = workspaceState.get<number>("monitor.logPaneHeight");
    this.runBoardHeight = workspaceState.get<number>("monitor.runBoardHeight");
    // **知らない値は "all" へ倒す**(古い形の保存値もここで落ちる) —— 台が黙って消えるより
    // 出しすぎるほうが安全
    const savedFilter = workspaceState.get<unknown>("monitor.platformFilter");
    this.platformFilter = isPlatformFilter(savedFilter) ? savedFilter : "all";
    // 既定 true(webview 側 splitter.js の「!== false」と揃える。片方だけ変えない)。
    this.logViewVisible = workspaceState.get<boolean>("monitor.logViewVisible", true);
    this.gridViewVisible = workspaceState.get<boolean>("monitor.gridViewVisible", true);
    // 既定 展開(webview 側 runBoard.js の初期値と揃える)。
    this.runBoardCollapsed = workspaceState.get<boolean>("monitor.runBoardCollapsed", false);
    this.runBoardExpandAll = workspaceState.get<boolean>("monitor.runBoardExpandAll", false);
    // 既定 OFF(選んでいない状態から始める。webview 側 deviceTiles.js の初期値と揃える)。
    this.selectAllDevices = workspaceState.get<boolean>("monitor.selectAllDevices", false);
    // 既定 ON = run 中も配信する(webview 側 streamToggle.js の初期値と揃える)。
    this.showStreamDuringRun = workspaceState.get<boolean>("monitor.showStreamDuringRun", true);
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
      isPanelActive: () => this.panel !== undefined,
      writeMonitorControl: (cmd) => this.processManager.writeMonitorControl(cmd),
      notifyProjectDeviceCatalogChanged: () => this.profiles.postProfileInfo(),
      restartMonitor: () => {
        if (this.panel) {
          this.processManager.restartMonitorProcess();
        }
      },
      unregisterDeletedDevice: (platform, name, machine) =>
        this.profiles.unregisterDeletedDevice(platform, name, machine),
      openGeneratedDocument: (filePath) => this.openGeneratedDocument(filePath),
      isDeviceStreaming: (deviceId) => this.deviceStream.isStreaming(deviceId),
      getStreamingDeviceIds: () => this.deviceStream.streamingIds(),
      notifyMonitorDevices: (devices) => {
        this.deviceOps.syncCpuRenderNames(devices);
        this.deviceStream.applyDevices(devices);
        this.bridgeWatchdog.observe(devices);
        this.healthWatchdog.observe(devices);
      },
      notifyMachineLocks: (locks) => {
        // 占有が変わった瞬間に畳む/戻す(次の monitorDevices を待たない = run の開始直後に
        // 配信が残っている時間を作らない)
        this.lastMachineLocks = locks;
        this.deviceStream.setOccupiedMachines(streamFoldMachines(locks, this.showStreamDuringRun));
      },
      isPollingMode: () => this.pollingMode,
      isShowStreamDuringRun: () => this.showStreamDuringRun,
      machineLock: (machine) => this.processManager.machineLock(machine),
      stopDeviceStreams: (name, machine) => this.deviceStream.disposeForDeviceName(name, machine),
      stopAllStreams: () => this.deviceStream.disposeAllForDown(),
      videoWebviewUri: (absPath) =>
        this.panel ? this.panel.webview.asWebviewUri(vscode.Uri.file(absPath)).toString() : null,
      runFleetestCli: (args) => this.runFleetestCli(args),
      showSaveDialog: async (defaultAbsPath, filterLabel) => {
        const uri = await vscode.window.showSaveDialog({
          defaultUri: vscode.Uri.file(defaultAbsPath),
          filters: { [filterLabel]: ["xlsx"] },
        });
        return uri?.fsPath;
      },
      showInfo: async (message, actionLabel) => {
        if (actionLabel === undefined) {
          await vscode.window.showInformationMessage(message);
          return undefined;
        }
        return vscode.window.showInformationMessage(message, actionLabel);
      },
      showError: (message) => void vscode.window.showErrorMessage(message),
      openExternal: (absPath) => void vscode.env.openExternal(vscode.Uri.file(absPath)),
    };
    this.deviceStream = new MonitorDeviceStreamController(this.deps);
    this.processManager = new MonitorProcessManager(this.deps);
    this.profiles = new MonitorProfilesController(this.deps);
    this.deviceOps = new MonitorDeviceOps(this.deps);
    this.recordings = new MonitorRecordingsController(
      this.deps,
      {
        get: () => workspaceState.get<boolean>("monitor.recordingsAllProjects", false),
        set: (value) => void workspaceState.update("monitor.recordingsAllProjects", value),
      },
      workspaceRecordingsSessionsCache(workspaceState),
    );
    this.update = new MonitorUpdateController({
      workspaceRoot: this.workspaceRoot,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message as never),
    });
    this.dashboard = new MonitorDashboardController({
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post({ type: "dashboard", message }),
      isPanelActive: () => this.panel !== undefined,
    });
    this.live = new LiveTabHost(
      {
        post: (message) => this.post(message),
        isPanelOpen: () => this.panel !== undefined,
        showTab: (tab) => this.showTabQuietly(tab),
        openGeneratedDocument: (filePath) => this.openGeneratedDocument(filePath),
        isPollingMode: () => this.pollingMode,
      },
      this.getConfig,
      this.cli,
      testTree,
      eventBus,
      this.workspaceRoot,
      this.outputChannel,
    );
    // enqueueLifecycleJob 委譲のため deviceOps より後に生成する。
    this.bridgeWatchdog = new MonitorBridgeWatchdog({
      post: (message) => this.post(message),
      log: (message) => this.outputChannel.appendLine(message),
      enqueueLifecycleJob: (job) => this.deviceOps.enqueueLifecycleJob(job),
      isAutoRepairEnabled: () => this.getConfig().autoRepairBridge,
      isAnyRunActive: () => isAnyLaneRunning(this.laneState),
      isDeviceLifecycleQueueBusy: () => this.deviceOps.isQueueBusy(),
    });
    // enqueueRestart 委譲のため deviceOps より後に生成する(bridgeWatchdog と同じ理由)。
    this.healthWatchdog = new MonitorHealthWatchdog({
      post: (message) => this.post(message),
      log: (message) => this.outputChannel.appendLine(message),
      enqueueRestart: (name) => this.deviceOps.enqueueRestart(name),
      forceCpuRender: (name) => this.deviceOps.markCpuRender(name),
      runWifiRepair: (serial) => {
        const adb = resolveAdb();
        return adb ? repairWifi(adb, serial) : Promise.resolve(false);
      },
      runDisplayRepair: (serial) =>
        repairDisplay(this.getConfig().binaryPath, this.workspaceRoot, serial),
      restartStream: (name) => this.deviceStream.restartForDeviceName(name),
      isAutoRepairEnabled: () => this.getConfig().autoRepairDeviceHealth,
      isDeviceLifecycleQueueBusy: () => this.deviceOps.isQueueBusy(),
    });

    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
    this.configChangeSubscription = vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("fleetest.profile") || event.affectsConfiguration("fleetest.project")) {
        // fleetest.project の変更は対象プロジェクトのデバイスカタログにも影響するため、
        // postProfileInfo() が両方を1回で最新化する。
        this.profiles.postProfileInfo();
        this.restartMonitorIfScopeChanged();
      }
      // 表示フィルタの変更は監視スコープを変えない(モニター再起動なしで即時反映する)。
      // 「起動中のデバイス」選択時は profile と 2 設定同時に変わるため、両分岐が走る。
      if (event.affectsConfiguration("fleetest.monitorDeviceFilter")) {
        this.profiles.postProfileInfo();
        this.processManager.repostDevicesWithCurrentFilter();
      }
      // Select Project(fleetest.project の設定更新)にダッシュボードタブも追従する。テストビューは
      // 設定変更で refresh するのにこのタブだけ据え置きだと、切り替えたのにヘッダが旧プロジェクトの
      // まま、に見える(実害)。
      if (event.affectsConfiguration("fleetest.project")) {
        this.dashboard.onProjectSettingChanged();
        this.recordings.onProjectSettingChanged();
        if (this.panel) {
          void this.recordings.refreshSessions();
        }
      }
    });
  }

  /**
   * 監視スコープ(project+profile)が実際に変わった場合のみモニターを再起動する。
   * プロジェクト未解決時は何もしない(既存のエラーバナー表示に任せる)。
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
    if (scope === this.processManager.monitorScope) {
      return;
    }
    this.processManager.restartMonitorProcess();
  }

  /** MonitorPanelDeps.runFleetestCli の実装。stdout は人向けの文(JSON でない)なので NDJSON
   * モードにして行ごとに出力パネルへ流す(defaultProject.ts の ensureDefaultProject と同じ形)。
   * 例外・非0終了は ok:false として返す(呼び出し側はここで throw を気にせず結果だけ見る)。 */
  private async runFleetestCli(args: readonly string[]): Promise<{ readonly ok: boolean; readonly output: string }> {
    const tail: string[] = [];
    try {
      const result = await this.cli.invoke(this.getConfig().binaryPath, this.workspaceRoot, {
        args: [...args],
        onNdjsonValue: () => undefined,
        onLog: (line) => {
          tail.push(line);
          this.outputChannel.appendLine(line);
        },
      });
      return { ok: result.exitCode === 0, output: tail.slice(-3).join(" / ") };
    } catch (error) {
      return { ok: false, output: error instanceof Error ? error.message : String(error) };
    }
  }

  /** モニターは ViewColumn.Beside(通常2列目以降)に開く。生成ソースはその1つ左(モニターが
   * 最左なら右隣)の列に開き、モニター表示を覆わないようにする。panel非表示時(viewColumn
   * undefined)は Two とみなし1列目に開く。 */
  private openGeneratedDocument(filePath: string): void {
    const monitorColumn = this.panel?.viewColumn ?? vscode.ViewColumn.Two;
    const target: vscode.ViewColumn =
      monitorColumn > vscode.ViewColumn.One ? monitorColumn - 1 : monitorColumn + 1;
    void vscode.window.showTextDocument(vscode.Uri.file(filePath), { viewColumn: target });
  }

  /** initialTab を指定すると、パネルが既に開いている場合は reveal 後にそのタブへ切り替える。
   * 新規作成の場合は pendingInitialTab に保持し sendInitialState() で送る。 */
  /** 「ライブ操作」タブへの自動切替(Run Test 開始・タイル右クリック)。開いているモニターは列を動かさず
   * エディタのフォーカスも奪わない(show() の reveal(Beside) はモニターを別の列へ動かす)。 */
  private showTabQuietly(tab: string): void {
    if (!this.panel) {
      this.show(tab);
      return;
    }
    this.panel.reveal(undefined, true);
    this.post({ type: "switchTab", tab });
  }

  show(initialTab?: string): void {
    if (this.panel) {
      this.panel.reveal(vscode.ViewColumn.Beside);
      if (initialTab) {
        this.post({ type: "switchTab", tab: initialTab });
      }
      return;
    }

    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, PANEL_TITLE, vscode.ViewColumn.Beside, {
      enableScripts: true,
      retainContextWhenHidden: true,
      // TestProjects/ 配下は録画タブの動画(mp4)読み込みに必要(monitorRecordingsController.ts が
      // asWebviewUri で変換するファイルはこの配下)。
      localResourceRoots: [
        vscode.Uri.joinPath(this.extensionUri, "media"),
        vscode.Uri.joinPath(vscode.Uri.file(this.workspaceRoot), "TestProjects"),
      ],
    });
    this.panel = panel;
    panel.webview.html = renderHtml(panel.webview, this.extensionUri);

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    // パネルが他タブの裏に隠れている間はストリーミング helper を止める(isPanelActive とは別軸:
    // こちらは実際の表示可否。再表示後は次の monitorDevices イベントで再構築される)。
    panel.onDidChangeViewState((event) => {
      this.panelVisible = event.webviewPanel.visible;
      this.applyDeviceStreamVisibility();
      // 「ライブ操作」タブの自動フレーム更新を止める/再開するため webview へも伝える(対向:
      // src/webview/monitor/main.js の updateLiveVisible。タブ自体が非表示なら効果は無い)。
      this.post({ type: "panelVisible", visible: event.webviewPanel.visible });
    });
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.processManager.stopMonitorProcess();
      this.processManager.stopHostMetricsProcess();
      this.deviceStream.dispose();
      this.dashboard.dispose();
      this.live.stopProcesses();
    });

    this.pendingInitialTab = initialTab;
    this.processManager.startAll();
    // 初期状態はここで送らない: html設定直後のpostMessageはwebview側のmessageリスナー登録前に
    // 届き握りつぶされる(VS Code既知のレース)。webviewからの"ready"を受けてsendInitialState()で送る。
  }

  /** fleetest.language 変更で extension.ts から呼ぶ。webview.html の再代入は webview を再読込するため
   * (JS 再実行・"ready" 再送。sendInitialState() は冪等なので状態は追いつく)、稼働中のライブ配信は
   * ブラウザ側デコーダごと失われる。restartMonitor と同じ理由で再読込後にストリームを張り直し、
   * 新キーフレームからタイル餓死無しに再開させる(restartAllStreams のコメント参照)。
   * パネル未生成時は何もしない。 */
  relocalize(): void {
    if (!this.panel) {
      return;
    }
    this.panel.webview.html = renderHtml(this.panel.webview, this.extensionUri);
    this.deviceStream.restartAllStreams();
    this.live.restartStream();
  }

  dispose(): void {
    this.profiles.disposePendingNameInput();
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profiles.disposeWatchers();
    this.processManager.stopMonitorProcess();
    this.processManager.stopHostMetricsProcess();
    this.deviceStream.dispose();
    this.dashboard.dispose();
    this.live.dispose();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  /** Run Test 実行前(runHandler.ts)から呼ばれる。 */
  async prepareForRun(platform: "ios" | "android"): Promise<LiveRunTarget | undefined> {
    return await this.live.prepareForRun(platform);
  }

  /** fleetest.showLiveControl コマンド。 */
  showLiveControl(): void {
    this.live.show();
  }

  private post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
  }

  private remoteHostsDeps(): RemoteHostsCliDeps {
    return {
      workspaceRoot: this.workspaceRoot,
      outputChannel: this.outputChannel,
      getConfig: this.getConfig,
      // 参照/書き込みとも短命な単発コマンドのため、device-catalog 等と同じくパネル破棄時の
      // キャンセル対象にはしない(登録せず終了を待つだけ)。
      registerChild: () => {},
    };
  }

  /**
   * 設定タブのリモートホスト行編集(追加・削除・machine/host/dir 変更)を CLI 登録簿へ反映する。
   * lastKnownRemoteHosts との差分だけを送る(diffRemoteHostsForSync)。削除→追加(import は upsert)
   * の順で送ることで、rename(同じ行の machine 変更)も「旧名を消し新名を作る」として正しく扱える。
   * CLI 呼び出しが失敗した行は lastKnownRemoteHosts に残らない(=書き込めなかったことが
   * 次に webview へ返す一覧に反映される)。失敗理由は remoteConfig.error に乗せて webview へ返す
   * (settingsTab.js が画面に出す。OUTPUT へのログだけにしない —— 行が黙って消えて見える)。
   */
  private async syncRemoteHostsFromWebview(hosts: readonly RemoteHostEntry[]): Promise<void> {
    const deps = this.remoteHostsDeps();
    const { removedNames, upserts } = diffRemoteHostsForSync(this.lastKnownRemoteHosts, hosts);
    let finalHosts = this.lastKnownRemoteHosts;
    let error: string | undefined;
    for (const name of removedNames) {
      const result = await removeRemoteHost(deps, name);
      if (result.hosts !== undefined) {
        finalHosts = result.hosts;
      } else {
        error = result.error;
      }
      this.noteRemoteHostsOutcome(result);
    }
    if (upserts.length > 0) {
      const result = await importRemoteHosts(deps, upserts);
      if (result.hosts !== undefined) {
        finalHosts = result.hosts;
      } else {
        error = result.error;
      }
      this.noteRemoteHostsOutcome(result);
    }
    this.lastKnownRemoteHosts = finalHosts;

    // CLI が返した確定形(書き込めなかった行の除外・machine の実値を含む)で webview を必ず作り直す。
    this.post({ type: "remoteConfig", hosts: finalHosts, error,
                defaultFMConcurrency: this.lastKnownDefaultFMConcurrency,
                local: this.lastKnownLocalMachine,
                machineColors: this.lastKnownMachineColors });
  }

  /** 設定タブのマシン削除の確認(webview の window.confirm は効かないのでホスト側で出す)。
   *  削除そのものは webview が行を消して setRemoteConfig で送る(差分計算を1経路に保つ)。 */
  private async confirmRemoveRemoteHost(rowId: number, machine: string): Promise<void> {
    const removeLabel = t("monitor.remoteHosts.removeButton");
    const choice = await vscode.window.showWarningMessage(
      t("monitor.remoteHosts.removeConfirm", { machine }),
      { modal: true, detail: t("monitor.remoteHosts.removeConfirmDetail") },
      removeLabel,
    );
    if (choice === removeLabel) {
      this.post({ type: "remoteHostRemoveConfirmed", rowId });
    }
  }

  /** CLI 応答のうち **hosts[] 以外の欄**(この機械の固定行・既定の FM 枠)を控え直す。
   *  **書き込み系(import/remove)の応答からも必ず通す** —— 読み取り時にしか控えないと、
   *  直後に webview へ送り返す `local` が古いままになり、固定行に打った値が
   *  「打った瞬間に元へ戻る」= 変更できないという症状になる(実際に踏んだ)。
   *  応答に欄が無いときは**消さずに据え置く**(失敗応答で行ごと消さない)。 */
  private noteRemoteHostsOutcome(result: RemoteHostsCliOutcome): void {
    const merged = mergeRemoteHostsSideFields(
      { defaultFMConcurrency: this.lastKnownDefaultFMConcurrency, local: this.lastKnownLocalMachine,
        machineColors: this.lastKnownMachineColors },
      result,
    );
    this.lastKnownDefaultFMConcurrency = merged.defaultFMConcurrency;
    this.lastKnownLocalMachine = merged.local;
    this.lastKnownMachineColors = merged.machineColors;
  }

  /** クリーンアップ設定の CLI 呼び出しも、リモートホスト登録簿と同じ短命ワンショット
   *  (キャンセル対象に登録せず終了を待つだけ)。 */
  private retentionDeps(): RetentionCliDeps {
    return this.remoteHostsDeps();
  }

  /**
   * 設定タブ「ログ・録画」のクリーンアップ欄の欄変更を CLI 側のマシン設定へ反映する。**書き込み後は必ず
   * CLI が返した確定形で webview を作り直す**(マシン登録簿と同じ規律)—— 拡張は保持ポリシーを
   * 持たないので、打った値が本当に入ったかは CLI の応答でしか分からない。失敗理由は
   * retention.error に乗せて webview へ返す(OUTPUT へのログだけにしない = 値が黙って戻る)。
   */
  private async applyRetentionPatch(patch: RetentionPatch): Promise<void> {
    const deps = this.retentionDeps();
    const result = await updateRetention(deps, patch);
    if (result.error === undefined) {
      this.post({ type: "retention", ...result });
      return;
    }
    // 書き込みに失敗した回は**現在値を読み直して理由と一緒に返す** —— 応答が理由だけだと
    // webview は「ポリシーを読めない古い CLI」と区別できず、欄ごと無効になって次に開き直すまで
    // 直せなくなる。読み直しも失敗したなら本当に使えないので理由だけを返す。
    const refreshed = await fetchRetention(deps);
    this.post(
      refreshed.error === undefined
        ? { type: "retention", ...refreshed, error: result.error }
        : { type: "retention", error: result.error },
    );
  }

  /**
   * 「今すぐクリーンアップ」。**消す前に必ず1回聞く**(破壊的操作)—— 先に `--dry-run` を撃って消える合計を
   * 見せ、ホスト側のモーダルで確認してから実行する(webview では window.confirm が効かない)。
   * 実行後は retention を読み直して使用量ごと配り直す(掃除で必ず変わるため)。
   * dryRun=true で来たときは見積もるだけで確認もしない。
   */
  private async handleRunCleanup(dryRun: boolean): Promise<void> {
    const deps = this.retentionDeps();
    this.post({ type: "retention", cleanup: { state: "running", dryRun } });
    const preview = await runCleanup(deps, true);
    if (preview.error !== undefined) {
      this.post({ type: "retention", cleanup: { state: "failed", dryRun, error: preview.error } });
      return;
    }
    if (dryRun) {
      this.post({ type: "retention", cleanup: { state: "done", dryRun: true, freedBytes: preview.freedBytes } });
      return;
    }
    const proceed = t("monitor.cleanup.confirmButton");
    const message =
      preview.freedBytes === undefined
        ? t("monitor.cleanup.confirmMessageUnknownSize")
        : t("monitor.cleanup.confirmMessage", { size: formatBytesAuto(preview.freedBytes) });
    const choice = await vscode.window.showWarningMessage(message, { modal: true }, proceed);
    if (choice !== proceed) {
      this.post({ type: "retention", cleanup: { state: "cancelled" } });
      return;
    }
    const result = await runCleanup(deps, false);
    if (result.error !== undefined) {
      this.post({ type: "retention", cleanup: { state: "failed", error: result.error } });
      return;
    }
    // 使用量は掃除で必ず変わる。初回表示と同じ2段で読む(使用量の集計は実測 21 秒かかるので、
    // 結果を先に出してから埋める。webview は done を見て古い使用量を消しておく)
    const refreshed = await fetchRetention(deps);
    this.post({
      type: "retention",
      ...refreshed,
      cleanup: { state: "done", dryRun: false, freedBytes: result.freedBytes },
    });
    if (refreshed.error !== undefined) {
      return;
    }
    const withUsage = await fetchRetentionUsage(deps);
    if (withUsage.error === undefined) {
      this.post({ type: "retention", ...withUsage });
    }
  }

  private hydrateLaneUi(): void {
    if (this.laneSectionVisible) {
      this.post({ type: "laneSectionVisible", visible: true });
    }
    const snapshot = snapshotRunLaneState(this.laneState);
    if (snapshot.lanes.length > 0 || Object.keys(snapshot.linesByLane).length > 0) {
      this.post({ type: "laneHydrate", snapshot });
    }
  }

  private handleBusMessage(message: RunBusMessage): void {
    switch (message.type) {
      case "runStarted":
        this.busRunActive = true;
        this.laneSectionVisible = true;
        this.post({ type: "laneSectionVisible", visible: true });
        this.setTestRunActive(true);
        this.setRecordingsFinalizing(false);
        this.dashboard.noteRunStarted(message.isDryRun);
        break;
      case "event":
        if (message.event.kind === "wipeStatus") {
          this.handleWipeStatusEvent(message.event.device, message.event.phase);
        }
        if (message.event.kind === "recordingFinalizing") {
          this.setRecordingsFinalizing(true);
        }
        for (const action of reduceLaneEvent(this.laneState, message.event, Date.now())) {
          this.post({ type: "runEvent", action });
        }
        break;
      case "runEnded":
        this.busRunActive = false;
        // runFinished未受信のまま終了(異常終了/キャンセル)した場合の後始末。正常終了時は無害(no-op)。
        for (const action of forceEndRunLaneState(this.laneState)) {
          this.post({ type: "runEvent", action });
        }
        for (const name of this.wipeInProgress) {
          this.post({ type: "wipeStatus", name, phase: "done" });
        }
        this.wipeInProgress.clear();
        // 録画タブを開いたまま実行すると、一覧の更新契機(タブ活性化・更新ボタン・再生からの戻る)
        // がどれも起きず、終わった run が出ないままになる。runEnded は NDJSON プロセス終了後
        // (= recordings/index.json 書き出し済み。リモート分の回収も済み)なので、ここで取り直せば競合しない。
        void this.recordings.refreshSessions();
        // 「録画を編集中」は録画タブへ移る(revealRun の post)まで出したままにする。録画が読めない
        // run・キャンセルでもここで必ず消す(次の runStarted まで残さない)
        if (message.resultRun) {
          void this.recordings
            .revealRun(message.resultRun.project, message.resultRun.runID)
            .finally(() => this.setRecordingsFinalizing(false));
        } else {
          this.setRecordingsFinalizing(false);
        }
        this.setTestRunActive(false);
        this.dashboard.noteRunEnded();
        break;
    }
  }

  /**
   * 「テストを実行」ボタンは**まず「デバイスを全て起動」と同じ処理**を通す(ユーザー決定)。
   * タイルの「起動待機」バッジはこのライフサイクルキューからしか出ないので、run 内の供給
   * (ApiRunCommand → AndroidLaneRecovery)に任せるとボタンから起動したときだけ無表示になっていた。
   * **run 内の供給は消せない** —— Test Explorer からの実行・CLI・リモート機にはモニターが居ない
   * (あちらは冪等なので、ここで起こしてあれば起動済みとして素通りする)。
   *
   * 実行そのものは Test Explorer の run プロファイルが持つ(runHandler.ts)。ここから直に CLI を
   * 起こすと結果がツリーへ載らず、進行も TEST RESULTS に出ない。
   */
  private async startTestRunAfterDevicesUp(): Promise<void> {
    if (this.pendingRunStart || this.testRunActive) {
      return;
    }
    this.pendingRunStart = true;
    this.runStartAborted = false;
    // 起動を待っている間もツールバーは実行中の見た目にする(= 中断の口を出す・連打を塞ぐ)
    this.setTestRunActive(true);
    this.deviceOps.bulkUpWithRestarts([]);
    await this.deviceOps.whenLifecycleQueueIdle();
    this.pendingRunStart = false;
    if (this.runStartAborted) {
      this.setTestRunActive(false);
      return;
    }
    // コマンドは起こした run の終了(runEnded の後)か、run を始めずに抜けたとき(対象0件・プロジェクト
    // 未解決・互換チェック失敗・開始前の中断)に戻る。**後者では runEnded が来ない**ので、戻った時点で
    // run が走っていなければここで戻す(戻さないと「テストを中断」のまま固まる)
    try {
      await this.runAllTests();
    } finally {
      if (!this.busRunActive) {
        this.setTestRunActive(false);
      }
    }
  }

  /** 差し替え口(テストは vscode スタブの executeCommand を await できないため)。 */
  private async runAllTests(): Promise<void> {
    await vscode.commands.executeCommand("fleetest.runAllTests");
  }

  /** GUI 実行の進行を webview へ配る。**状態を持つ**のは webview 再読込(sendInitialState)で
   * 復元するため —— 失うと実行中なのにツールバーが操作可能に戻る。 */
  private setTestRunActive(active: boolean): void {
    this.testRunActive = active;
    this.post({ type: "testRunActive", active });
  }

  private setRecordingsFinalizing(active: boolean): void {
    this.recordingsFinalizing = active;
    this.post({ type: "recordingsFinalizing", active });
  }

  private handleWipeStatusEvent(name: string, phase: WipeStatusMessage["phase"]): void {
    if (phase === "stopping" || phase === "rebooting") {
      this.wipeInProgress.add(name);
    } else {
      this.wipeInProgress.delete(name);
    }
    this.post({ type: "wipeStatus", name, phase });
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
        this.deviceOps.bulkUpWithRestarts(message.restartNames ?? []);
        break;
      case "devicesUpCancel":
        this.deviceOps.cancelBulkUp();
        break;
      case "devicesDown":
        // **他人(あるいは自分)の run が走っている機械があれば先に言う**(§18.1 #6)。
        // 一括停止はリモート機のブリッジとシミュレータも畳むので、走っている run は必ず落ちる。
        // 手元の run は全掃討のときだけ止める(CLI も同じ lease で断る。bulkDownGate)。
        // 占有も手元の run も無いときは確認を挟まない(単独利用の手数を増やさない)
        void this.confirmThenBulkDown();
        break;
      case "restartMonitor":
        // ストリームを先に作り直す: streamingIds をクリアしてから monitor を再起動させることで、
        // 新モニターへの stale な suppressFrames 再送を防ぎ、新キーフレームでタイル餓死を回避する
        // (monitorDeviceStreamController.restartAllStreams 参照)。
        this.deviceStream.restartAllStreams();
        this.processManager.restartAll();
        // ツールバーの実行中表示も実体(run が走っているか・起動待ちか)に合わせ直す
        this.setTestRunActive(this.busRunActive || this.pendingRunStart);
        break;
      case "runTests":
        void this.startTestRunAfterDevicesUp();
        break;
      case "cancelTests":
        // run を投げる前(デバイス起動待ち)の中断は、一括起動を止めて run へ進まない。
        // この段では走っている run がまだ無いので cancelTestRun は撃たない。
        if (this.pendingRunStart) {
          this.runStartAborted = true;
          this.deviceOps.cancelBulkUp();
          break;
        }
        void vscode.commands.executeCommand("fleetest.cancelTestRun");
        break;
      case "copyText":
        void vscode.env.clipboard.writeText(message.text).then(() => {
          vscode.window.setStatusBarMessage(t("panels.banner.copied"), 3000);
        });
        break;
      case "devicesTabVisible":
        this.devicesTabVisible = message.visible;
        this.applyDeviceStreamVisibility();
        return;
      case "setRetention":
        void this.applyRetentionPatch(message.patch);
        break;
      case "runCleanup":
        void this.handleRunCleanup(message.dryRun);
        break;
      case "refreshResidentProcesses":
        void this.refreshResidentProcesses();
        break;
      case "killAllResidentProcessesAndClose":
        void this.killAllResidentProcessesAndClose();
        break;
      case "deviceUpCancel":
        this.deviceOps.cancelDeviceUp(message.name, message.machine);
        break;
      case "deviceOp":
        // 「マシン有効」off の機械の台は起動しない(webview のメニューも無効化している。これは古い
        // メニュー状態から届いた要求の門)。登録簿を読めていなければ通す(不明を無効と読まない)
        if (message.op === "up" && this.remoteHostsLoaded
            && disabledMachineSet(this.lastKnownRemoteHosts, this.lastKnownLocalMachine)
              .has(message.machine ?? "local")) {
          this.outputChannel.appendLine(t("deviceOps.log.startRefusedMachineDisabled",
            { name: message.name, machine: message.machine ?? "local" }));
          break;
        }
        this.deviceOps.enqueueLifecycleJob({
          kind: "device", name: message.name, op: message.op, machine: message.machine,
          udid: message.udid, serial: message.serial,
        });
        break;
      case "openLiveForDevice":
        this.live.openForDevice(message.id, message.remote);
        break;
      case "deviceRestartGpu":
        this.deviceOps.restartWithGpu(message.name, message.machine);
        break;
      case "devicesRestartGpu":
        this.deviceOps.restartWithGpuBatch(message.devices);
        break;
      case "selectProfile":
        this.profiles.selectProfile(message.profile);
        break;
      case "selectProject":
        this.profiles.selectProject(message.project);
        break;
      case "projectAdd":
        void this.profiles.handleProjectAdd();
        break;
      case "projectCopy":
        void this.profiles.handleProjectCopy(message.project);
        break;
      case "projectDelete":
        void this.profiles.handleProjectDelete(message.project);
        break;
      case "projectRename":
        void this.profiles.handleProjectRename(message.project);
        break;
      case "profileAdd":
        void this.profiles.handleProfileAdd();
        break;
      case "profileCopy":
        void this.profiles.handleProfileCopy(message.profile);
        break;
      case "profileDelete":
        void this.profiles.handleProfileDelete(message.profile);
        break;
      case "profileRename":
        void this.profiles.handleProfileRename(message.profile);
        break;
      case "deviceCatalogRequest":
        this.deviceOps.runDeviceCatalog(message.source);
        break;
      case "installCmdlineToolsRequest":
        this.deviceOps.runInstallCmdlineTools();
        break;
      case "createDevice":
        this.deviceOps.runCreateDevice(message);
        break;
      case "batchCreateDevices":
        void this.deviceOps.runBatchCreateDevices(message);
        break;
      case "installedDevicesRequest":
        this.deviceOps.runInstalledDevices(message.source);
        break;
      case "devicePickDeviceDelete":
        void this.deviceOps.runDeleteDevice(message);
        break;
      case "runProfileDevicesSync":
        this.profiles.handleRunProfileDevicesSync(message);
        break;
      case "runProfileDeviceRemove":
        void this.profiles.handleRunProfileDeviceRemove(message.devices);
        break;
      case "runProfileDeviceWipe":
        void this.deviceOps.runWipeDevices(message.devices);
        break;
      case "runProfileLoad":
        this.profiles.handleRunProfileLoad(message.profile);
        break;
      case "runProfileSave":
        this.profiles.handleRunProfileSave(message);
        break;
      case "runProfileHookScaffold":
        void this.profiles.handleRunProfileHookScaffold(message);
        break;
      case "appProfileAdd":
        void this.profiles.handleAppProfileAdd();
        break;
      case "appProfileCopy":
        void this.profiles.handleAppProfileCopy(message.profile);
        break;
      case "appProfileDelete":
        void this.profiles.handleAppProfileDelete(message.profile);
        break;
      case "appProfileRename":
        void this.profiles.handleAppProfileRename(message.profile);
        break;
      case "appProfileLoad":
        this.profiles.handleAppProfileLoad(message.profile);
        break;
      case "appProfileSave":
        this.profiles.handleAppProfileSave(message);
        break;
      case "nameInputConfirm":
        this.profiles.resolveNameInput(message.id, message.name);
        break;
      case "nameInputCancel":
        this.profiles.cancelNameInput(message.id);
        break;
      case "checkUpdate":
        // 人が押した確認なので、更新が見つかったらその場で適用するか聞く(prompt)。
        void this.update.check({ prompt: true });
        break;
      case "runUpdate":
        void this.update.runUpdate();
        break;
      case "setPollingMode":
        this.pollingMode = message.value;
        void this.workspaceState.update("monitor.pollingMode", message.value);
        // トグル直後に即時反映する(次の monitorDevices イベント待ちにしない)のはタイルの配信だけ。
        // 「ライブ操作」タブ(LiveTabHost)は isPollingMode() を毎回読み直す作りのため、
        // 次のデバイス選択/表示状態変化で自然に追いつく(強制の再評価は不要)。
        this.deviceStream.reapply();
        break;
      case "setLptHistoryRuns":
        // null = 入力欄が空・不正値 → 設定を消して既定へ戻す(webview 側は入力欄を空欄にする)
        void vscode.workspace
          .getConfiguration("fleetest")
          .update("lptHistoryRuns", message.value ?? undefined, vscode.ConfigurationTarget.Global);
        return;
      case "setRemoteWaitLock":
        // null = 入力欄が空・不正値 → 設定を消して既定へ戻す(0 は「待たない」の正当な値なので
        // undefined へ倒さない)。次の run から効く(走っている run の待ちは変わらない)。
        // CLI へは runHandler.ts が 0 より大きいときだけ --wait-lock を渡す。
        void vscode.workspace
          .getConfiguration("fleetest")
          .update("remoteWaitLock", message.value ?? undefined, vscode.ConfigurationTarget.Global);
        return;
      case "setLptScheduling":
        // 次の run から効く(実行中の run の順序は変わらない)。CLI へは runHandler.ts が
        // false のとき --no-lpt を渡す。
        void vscode.workspace
          .getConfiguration("fleetest")
          .update("lptScheduling", message.value, vscode.ConfigurationTarget.Global);
        return;
      case "setLanguage":
        // fleetest.language 設定(Global)を更新。反映(ツリー再翻訳 + 再読み込み案内)は
        // extension.ts の onDidChangeConfiguration ハンドラが担う。
        void vscode.workspace
          .getConfiguration("fleetest")
          .update("language", message.value, vscode.ConfigurationTarget.Global);
        break;
      case "setRemoteConfig": {
        void this.syncRemoteHostsFromWebview(message.hosts);
        break;
      }
      case "requestRemoveRemoteHost":
        void this.confirmRemoveRemoteHost(message.rowId, message.machine);
        break;
      case "setTilePaneHeight":
        this.tilePaneHeight = message.value;
        void this.workspaceState.update("monitor.tilePaneHeight", message.value);
        break;
      case "setFleetVisible":
        this.fleetVisible = message.value;
        void this.workspaceState.update("monitor.fleetVisible", message.value);
        break;
      case "setPlatformFilter":
        this.platformFilter = message.value;
        void this.workspaceState.update("monitor.platformFilter", this.platformFilter);
        break;
      case "setRunBoardHeight":
        this.runBoardHeight = message.value;
        void this.workspaceState.update("monitor.runBoardHeight", message.value);
        break;
      case "setLogPaneHeight":
        this.logPaneHeight = message.value;
        void this.workspaceState.update("monitor.logPaneHeight", message.value);
        break;
      case "setLogViewVisible":
        this.logViewVisible = message.value;
        void this.workspaceState.update("monitor.logViewVisible", message.value);
        break;
      case "setGridViewVisible":
        this.gridViewVisible = message.value;
        void this.workspaceState.update("monitor.gridViewVisible", message.value);
        break;
      case "setRunBoardCollapsed":
        this.runBoardCollapsed = message.value;
        void this.workspaceState.update("monitor.runBoardCollapsed", message.value);
        break;
      case "setRunBoardExpandAll":
        this.runBoardExpandAll = message.value;
        void this.workspaceState.update("monitor.runBoardExpandAll", message.value);
        break;
      case "setSelectAllDevices":
        this.selectAllDevices = message.value;
        void this.workspaceState.update("monitor.selectAllDevices", message.value);
        break;
      case "setShowStreamDuringRun":
        this.showStreamDuringRun = message.value;
        void this.workspaceState.update("monitor.showStreamDuringRun", message.value);
        // 次の monitorDevices を待たずに畳む/張り直す(setOccupiedMachines は変化が無いと再判定しない)
        this.deviceStream.setOccupiedMachines(streamFoldMachines(this.lastMachineLocks, message.value));
        this.applyDeviceStreamVisibility();
        this.deviceStream.reapply();
        break;
      case "streamRendered":
        // webview がストリームフレームを描画できた ack。これを受けて初めてポーリングを間引く
        // (契約: monitorDeviceStreamController.ts 冒頭)
        if (message.device) {
          this.deviceStream.noteStreamRendered(message.device);
        }
        break;
      case "streamStall":
        if (message.scope === "live") {
          this.outputChannel.appendLine(t("live.panel.streamStallRestart"));
          this.live.restartStream();
        } else if (message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: ${t("monitor.log.streamStallRestart")}`,
          );
          this.deviceStream.restartDevice(message.device);
        }
        break;
      case "codecError":
        if (message.scope === "live") {
          this.outputChannel.appendLine(t("live.panel.codecFallback"));
          this.live.fallbackToMjpeg();
        } else if (message.scope === "tile" && message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: ${t("monitor.log.codecFallbackMjpeg")}`,
          );
          this.deviceStream.fallbackToMjpeg(message.device);
        }
        break;
      case "recordingsRefresh":
        void this.recordings.refreshSessions();
        break;
      case "recordingsSelectProject":
        void this.recordings.selectProject(message.project);
        break;
      case "recordingsOpen":
        void this.recordings.openSession(message.project, message.runID);
        break;
      case "recordingsExport":
        void this.recordings.exportSession(message.project, message.runID);
        break;
      case "dashboard":
        this.dashboard.handleWebviewMessage(message.message);
        break;
      case "live":
        this.live.handleWebviewMessage(message.message);
        break;
    }
  }

  /**
   * webviewからの"ready"を受けて初期状態をまとめて送る。readyはwebview再読込のたびに再送
   * されうるため、ここで呼ぶ各処理は冪等であること(いずれもwebview側で上書き描画するだけ)。
   */
  /** 一括停止の前に、占有中の機械があれば modal で確認する(webview の window.confirm は
   * 効かないのでホスト側で出す)。占有が無ければ即実行する。 */
  private async confirmThenBulkDown(): Promise<void> {
    const gate = bulkDownGate({
      // executeBulkJob と同じ判定(プロファイル未選択 = 全掃討の devices down)
      profileSelected: !!this.getConfig().profile,
      localInRun: this.processManager.localDevicesInRun(),
      occupied: this.processManager.occupiedMachineList(),
    });
    if (gate.kind === "blockedByLocalRun") {
      void vscode.window.showWarningMessage(
        t("deviceOps.bulkDownLocalRunMessage"),
        { modal: true, detail: t("deviceOps.bulkDownLocalRunDetail", {
          names: gate.names.join(t("deviceOps.nameSeparator")),
        }) },
      );
      return;
    }
    if (gate.kind === "confirmOccupied") {
      const holders = gate.holders
        // 手元(LOCAL_MACHINE_KEY = 空文字)はマシン名のスロットに既存の呼び名を入れる
        .map((entry) => `${entry.machine || t("deviceOps.machineLocalLabel")}: `
          + `${entry.issuer ?? t("deviceOps.occupiedIssuerUnknown")}`)
        .join(t("deviceOps.nameSeparator"));
      const confirmLabel = t("deviceOps.bulkDownOccupiedConfirmButton");
      const choice = await vscode.window.showWarningMessage(
        t("deviceOps.bulkDownOccupiedMessage"),
        { modal: true, detail: t("deviceOps.bulkDownOccupiedDetail", { holders }) },
        confirmLabel,
      );
      if (choice !== confirmLabel) {
        return;
      }
    }
    // 自分のライブ操作の台の印は自分で畳んでから撃つ(印が1本でもあると全掃討は丸ごと断られ、
    // プロファイル指定でもその台だけ「MCP session が駆動中」で残る)。掃討が終わったら立て直す
    await this.live.suspendServeForSweep();
    this.deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "down" });
    await this.deviceOps.whenLifecycleQueueIdle();
    this.live.resumeServeAfterSweep();
  }

  private sendInitialState(): void {
    this.hydrateLaneUi();
    // openForDevice() がモニター新規作成と同時に呼ばれていた場合の openDevice 送信保留分を flush する
    // (html設定直後の postMessage は webview 側リスナー登録前に届き握りつぶされるレース回避)。
    this.live.notifyReady();
    this.profiles.postProfileInfo();
    this.profiles.postProfileInfo();
    // webview再読込がジョブ実行中に起きた場合にボタン無効状態・タイルのバッジを復元するため。
    this.deviceOps.resendQueueStatus();
    // webview 再読込でホストグラフの行(手元 + リモート機)が消えるので配り直す
    this.processManager.postHostMetricsMachines();
    this.post({ type: "testRunActive", active: this.testRunActive });
    this.post({ type: "recordingsFinalizing", active: this.recordingsFinalizing });
    this.post({ type: "pollingMode", value: this.pollingMode });
    this.post({
      type: "lptScheduling",
      value: vscode.workspace.getConfiguration("fleetest").get<boolean>("lptScheduling", true),
    });
    // default は設定タブのプレースホルダに使う(Swift 側 LPTOrdering.defaultHistoryRuns と
    // package.json の既定値に一致させること。lptDefaultSync.test.mjs が検証)
    // value は明示設定だけ(未設定は null = 設定タブは空欄 + 既定のプレースホルダ)。get() は既定で
    // 埋めるので「既定と同じ値を明示」と「未設定」を区別できない → inspect の各層を見る
    const lptHistory = vscode.workspace.getConfiguration("fleetest").inspect<number>("lptHistoryRuns");
    this.post({
      type: "lptHistoryRuns",
      value: lptHistory?.workspaceFolderValue ?? lptHistory?.workspaceValue ?? lptHistory?.globalValue ?? null,
      default: 5,
    });
    // default は設定タブのプレースホルダ(package.json の fleetest.remoteWaitLock.default・
    // config.ts の readConfig と一致させること。remoteWaitLockDefaultSync.test.mjs が検証)。
    // value は lptHistoryRuns と同じく明示設定だけ(0 = 待たない は明示値なので ?? で null へ倒さない)
    const waitLock = vscode.workspace.getConfiguration("fleetest").inspect<number>("remoteWaitLock");
    this.post({
      type: "remoteWaitLock",
      value: waitLock?.workspaceFolderValue ?? waitLock?.workspaceValue ?? waitLock?.globalValue ?? null,
      default: 3600,
    });
    this.post({
      type: "language",
      value: vscode.workspace.getConfiguration("fleetest").get<"auto" | "ja" | "en">("language", "auto"),
    });
    {
      // hosts の正は CLI の LocalConfig(docs/remote-runner.md §13「原則」)。fetch は非同期なので
      // fire-and-forget で送り直す(失敗しても他の初期化を止めない。update-check と同じ方針)。
      void fetchRemoteHosts(this.remoteHostsDeps()).then((result) => {
        this.lastKnownRemoteHosts = result.hosts ?? [];
        this.noteRemoteHostsOutcome(result);
        this.remoteHostsLoaded = this.remoteHostsLoaded || result.hosts !== undefined;
        this.post({ type: "remoteConfig", hosts: this.lastKnownRemoteHosts,
                    defaultFMConcurrency: this.lastKnownDefaultFMConcurrency,
                local: this.lastKnownLocalMachine,
                machineColors: this.lastKnownMachineColors });
      });
    }
    // 設定タブ「ログ・録画」のクリーンアップ欄。**保持ポリシーの正は CLI 側のマシン設定**で、拡張は既定値を
    // 持たない。読めなければ error だけを配って webview がセクションを無効表示にする
    // (コマンドを持たない古い CLI でも他の初期化を止めない)。
    // **2段で読む**: 上限だけなら即座に返る(実測 0.9 秒)が、使用量の集計は全ファイルを
    // stat して回るので実測 21 秒かかる。1回で済ませると、その間ずっと入力欄が空欄になる
    void fetchRetention(this.retentionDeps()).then((result) => {
      this.post({ type: "retention", ...result });
      if (result.error !== undefined) {
        return;
      }
      void fetchRetentionUsage(this.retentionDeps()).then((withUsage) => {
        if (withUsage.error === undefined) {
          this.post({ type: "retention", ...withUsage });
        }
      });
    });
    if (this.tilePaneHeight !== undefined) {
      this.post({ type: "tilePaneHeight", value: this.tilePaneHeight });
    }
    // fleetVisible は selectAllDevices より先に送る(非表示なら webview が全選択から始める。main.js)
    this.post({ type: "fleetVisible", value: this.fleetVisible });
    if (this.logPaneHeight !== undefined) {
      this.post({ type: "logPaneHeight", value: this.logPaneHeight });
    }
    if (this.runBoardHeight !== undefined) {
      this.post({ type: "runBoardHeight", value: this.runBoardHeight });
    }
    this.post({ type: "platformFilter", value: this.platformFilter });
    this.post({ type: "logViewVisible", value: this.logViewVisible });
    this.post({ type: "gridViewVisible", value: this.gridViewVisible });
    this.post({ type: "runBoardCollapsed", value: this.runBoardCollapsed });
    this.post({ type: "runBoardExpandAll", value: this.runBoardExpandAll });
    this.post({ type: "selectAllDevices", value: this.selectAllDevices });
    this.post({ type: "showStreamDuringRun", value: this.showStreamDuringRun });
    // 設定タブの更新セクション。ネットワークに出るので ready のたびに1回だけ(webview 再読込は稀)。
    // 失敗しても他の初期化を止めない fire-and-forget
    void this.update.check();
    if (this.pendingInitialTab) {
      this.post({ type: "switchTab", tab: this.pendingInitialTab });
      this.pendingInitialTab = undefined;
    }
  }

  // UDID(大文字)→ シミュレータ名。親PID が launchd_sim のとき説明をデバイス名にするのに使う。
  // simctl は重いので 60 秒 TTL でキャッシュ(1 秒間隔の一覧更新で毎回叩かない)。
  private simulatorNames: Record<string, string> = {};
  private simulatorNamesFetchedAt = 0;

  // in-app ブリッジは pid ファイルを持たず、注入先アプリのプロセスとして走る。どのシミュレータに
  // 張られているかは `.fleetest/bridge-<port>.inapp`("<udid> <bundleID>" の1行)に記録される。
  // 実行のたびに変わるのでキャッシュせず毎回読む(小さいファイル数個)。
  private async readInappBridges(): Promise<Map<string, string>> {
    const dir = path.join(this.workspaceRoot, ".fleetest");
    const bridges = new Map<string, string>(); // UDID(大文字)→ ポート
    let entries: string[];
    try {
      entries = await fs.readdir(dir);
    } catch {
      return bridges;
    }
    await Promise.all(
      entries
        .filter((f) => f.endsWith(".inapp"))
        .map(async (f) => {
          const port = f.match(/^bridge-(\d+)\.inapp$/)?.[1] ?? "";
          try {
            const txt = await fs.readFile(path.join(dir, f), "utf8");
            const udid = txt.trim().split(/\s+/)[0];
            if (udid) {
              bridges.set(udid.toUpperCase(), port);
            }
          } catch {
            // stale/読めないファイルは無視
          }
        }),
    );
    return bridges;
  }

  private execAdb(adb: string, args: string[]): Promise<string> {
    return new Promise((resolve) => {
      execFile(adb, args, { timeout: 4000, env: childEnv() }, (err, out) => {
        resolve(err || !out ? "" : out);
      });
    });
  }

  // Android ブリッジはエミュレータ内の am instrument でホスト ps に出ない。ホスト側に残る
  // `adb forward tcp:<host> tcp:8123` の一覧から情報行を合成し、デバイス内 PID を
  // `adb shell pidof <bridgePackage>` で埋める(PID 列に "(12345)" 表示用)。adb 未検出なら空。
  private async listAndroidBridges(): Promise<ResidentProcess[]> {
    const adb = resolveAdb();
    if (!adb) {
      return [];
    }
    const forwardOut = await this.execAdb(adb, ["forward", "--list"]);
    if (!forwardOut) {
      return [];
    }
    const serials = parseAndroidBridges(forwardOut).map((r) => r.detail);
    // bridgePackage は Sources/FTAndroid/AndroidBridge.swift の bridgePackage と同期。
    const pidBySerial = new Map<string, number>();
    await Promise.all(
      serials.map(async (serial) => {
        const out = await this.execAdb(adb, ["-s", serial, "shell", "pidof", "com.example.ftbridge"]);
        const pid = Number.parseInt(out.trim().split(/\s+/)[0] ?? "", 10);
        if (Number.isInteger(pid) && pid > 0) {
          pidBySerial.set(serial, pid);
        }
      }),
    );
    return parseAndroidBridges(forwardOut, pidBySerial, currentLocale());
  }

  private async listResidentProcesses(simulatorNames: Record<string, string> = {}): Promise<ResidentProcess[]> {
    const [stdout, inappBridges, androidBridges] = await Promise.all([
      new Promise<string>((resolve) => {
        execFile("ps", ["-axo", "pid=,ppid=,state=,command="], { maxBuffer: 8 * 1024 * 1024, env: childEnv() }, (err, out) => {
          resolve(err ? "" : out);
        });
      }),
      this.readInappBridges(),
      this.listAndroidBridges(),
    ]);
    // config の binaryPath 配下(このリポジトリのビルド成果物)は名前を問わず fleetest 由来として拾う。
    const binaryDir = path.dirname(this.getConfig().binaryPath);
    // 表示・掃除の対象外を取得段階で除外する: Android エミュ本体(qemu、「デバイスモニター」タブの領域)と
    // MCP サーバ(mcp、セッションを守るため掃討しない=表示もしない)。
    const host = parseResidentProcesses(stdout, { simulatorNames, binaryDir, inappBridges, locale: currentLocale() }).filter(
      (p) => p.type !== "emulator" && p.type !== "mcp",
    );
    // 合成した android-bridge 行を混ぜ、TYPE_ORDER→pid で再整列(pid=0 同士は serial で安定化)。
    const merged = [...host, ...androidBridges];
    merged.sort((a, b) => {
      const d = TYPE_ORDER.indexOf(a.type) - TYPE_ORDER.indexOf(b.type);
      if (d !== 0) {
        return d;
      }
      return a.pid !== b.pid ? a.pid - b.pid : a.detail.localeCompare(b.detail);
    });
    return merged;
  }

  private async ensureSimulatorNames(): Promise<void> {
    const now = Date.now();
    if (now - this.simulatorNamesFetchedAt < 60000) {
      return;
    }
    this.simulatorNamesFetchedAt = now; // 先に更新して並行取得を防ぐ(失敗しても次は 60 秒後)
    const json = await new Promise<string>((resolve) => {
      execFile(
        "xcrun",
        ["simctl", "list", "devices", "-j"],
        { maxBuffer: 8 * 1024 * 1024, timeout: 8000, env: childEnv() },
        (err, out) => resolve(err ? "" : out),
      );
    });
    if (!json) {
      return;
    }
    try {
      const parsed = JSON.parse(json) as { devices?: Record<string, Array<{ udid?: string; name?: string }>> };
      const map: Record<string, string> = {};
      for (const list of Object.values(parsed.devices ?? {})) {
        for (const d of list) {
          if (d?.udid && d?.name) {
            map[String(d.udid).toUpperCase()] = String(d.name);
          }
        }
      }
      this.simulatorNames = map;
    } catch {
      // 壊れた JSON は無視(親説明は UDID 短縮にフォールバック)
    }
  }

  private async refreshResidentProcesses(): Promise<void> {
    await this.ensureSimulatorNames();
    const items = await this.listResidentProcesses(this.simulatorNames);
    this.post({ type: "residentProcesses", items, ts: Date.now() });
  }

  /** fleetest CLI を1回実行して完了(または 120s タイムアウト)まで待つ。exitCode は呼び手が見る
   *  (例: `bridge down` が lease/MCP の印で断られたかの判定)。null = 起動失敗・タイムアウトで
   *  強制終了(非 0 と同じ「成功していない」として扱う)。 */
  private runFleetest(args: string[]): Promise<{ readonly exitCode: number | null }> {
    return new Promise<{ readonly exitCode: number | null }>((resolve) => {
      const tag = args.join(" ");
      let proc: PipeProcess;
      try {
        proc = spawn(this.getConfig().binaryPath, args, {
          cwd: this.workspaceRoot,
          shell: false,
          env: childEnv(),
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e) {
        this.outputChannel.appendLine(`[fleetest] ${tag} ${t("monitor.log.launchFailed", { error: String(e) })}`);
        resolve({ exitCode: null });
        return;
      }
      const onLine = (stream: string, chunk: Buffer): void => {
        for (const raw of chunk.toString("utf8").split("\n")) {
          const line = raw.trim();
          if (line) {
            this.outputChannel.appendLine(`[${tag} ${stream}] ${line}`);
          }
        }
      };
      proc.stdout.on("data", (c: Buffer) => onLine("stdout", c));
      proc.stderr.on("data", (c: Buffer) => onLine("stderr", c));
      const timer = setTimeout(() => {
        try {
          proc.kill("SIGKILL");
        } catch {
          // already dead
        }
        resolve({ exitCode: null });
      }, 120000);
      proc.on("close", (code) => {
        clearTimeout(timer);
        resolve({ exitCode: code });
      });
      proc.on("error", () => {
        clearTimeout(timer);
        resolve({ exitCode: null });
      });
    });
  }

  // SIGKILL 掃討の対象を「この workspace 由来」に限定する判定。実行時の workspaceRoot / binaryDir を
  // 基準にするため VSIX にパスは焼き込まれない(配布先では各自の開いている workspace が基準になる)。
  // iOS ブリッジは xctestrun が <workspaceRoot>/.fleetest 配下、fleetest CLI/mcp/stream/run は binaryDir
  // から起動されるため一致する。sim-runner / in-app はコマンドに workspace パスを持たない(sim
  // コンテナ内)ため一致せず、それらは step 2 の bridge down --all に委ねる。
  private isWorkspaceOwned(command: string): boolean {
    if (command.includes(this.workspaceRoot)) {
      return true;
    }
    const binaryDir = path.dirname(this.getConfig().binaryPath);
    return path.isAbsolute(binaryDir) && command.includes(binaryDir);
  }

  // 掃討本体(確認ダイアログは killAllResidentProcessesAndClose が持つ)。
  private async killResidentProcessesCore(): Promise<void> {
    // 1) 自分の常駐子を respawn 抑止して停止(生 SIGKILL による respawn churn を防ぐため先に)。
    this.deviceStream.disposeAllForDown();
    this.processManager.stopMonitorProcess();
    this.processManager.stopHostMetricsProcess();
    // 2) iOS ブリッジをシミュレータ本体を残してクリーン停止(xcuitest+inapp。pid/inapp ファイル基準で
    //    SIGTERM→simctl terminate。simctl shutdown はしない=「デバイスモニター」タブの領域)。
    //    lease/MCP の印で断られる(非 0 終了)ことがあるため、断られた側は手順4の SIGKILL 対象から外す
    //    (planResidentKill の bridgeDownRefused/androidDownRefused)。
    const bridgeDown = await this.runFleetest(["bridge", "down", "--all"]);
    const bridgeDownRefused = bridgeDown.exitCode !== 0;
    if (bridgeDownRefused) {
      this.outputChannel.appendLine(
        t("monitor.log.residentKillBridgeRefused", { cmd: "bridge down --all", exitCode: bridgeDown.exitCode ?? "timeout" }),
      );
    }
    // 3) Android ブリッジを am force-stop + adb forward --remove で停止(qemu=エミュレータ本体は残す)。
    //    adb 未検出環境ではスキップ(出力ノイズを避ける。未実行 = 断られていないので android-bridge は
    //    手順4の対象に残る。android-bridge はホスト PID を持たない合成行なので実際には killed されない)。
    let androidDownRefused = false;
    if (resolveAdb()) {
      const androidDown = await this.runFleetest(["bridge", "down", "--platform", "android"]);
      androidDownRefused = androidDown.exitCode !== 0;
      if (androidDownRefused) {
        this.outputChannel.appendLine(
          t("monitor.log.residentKillBridgeRefused", { cmd: "bridge down --platform android", exitCode: androidDown.exitCode ?? "timeout" }),
        );
      }
    }
    // 4) 残余のホスト常駐を掃討。判定は planResidentKill(純粋関数)の1箇所 —— この workspace 由来
    //    (machine-wide の巻き込み・別 repo の同種プロセスへの誤爆を避ける)・断られたブリッジ型を除く・
    //    run 型は SIGTERM のみ(後始末を刺し殺さない。process-lifecycle.md)。
    const remaining = await this.listResidentProcesses();
    const targets = planResidentKill(remaining, {
      ownPid: process.pid,
      isWorkspaceOwned: (command) => this.isWorkspaceOwned(command),
      bridgeDownRefused,
      androidDownRefused,
    });
    for (const target of targets) {
      try {
        process.kill(target.pid, target.signal);
      } catch (e) {
        if ((e as NodeJS.ErrnoException)?.code !== "ESRCH") {
          this.outputChannel.appendLine(
            `[fleetest] ${t("monitor.log.residentKillFailed", { pid: target.pid, error: String(e) })}`,
          );
        }
      }
    }
  }

  /** 「すべて終了」ボタンの確認(破壊的操作。webview の window.confirm は効かないのでホスト側で出す)。
   *  キャンセル時は何もせず residentKillCancelled を返してボタンを戻す(処理は行わない)。 */
  private async killAllResidentProcessesAndClose(): Promise<void> {
    const before = await this.listResidentProcesses();
    const runCount = before.filter((p) => p.type === "run").length;
    const proceed = t("monitor.residentKillClose.confirmButton");
    const choice = await vscode.window.showWarningMessage(
      t("monitor.residentKillClose.confirmMessage"),
      { modal: true, detail: runCount > 0 ? t("monitor.residentKillClose.confirmDetailRuns", { count: runCount }) : undefined },
      proceed,
    );
    if (choice !== proceed) {
      this.post({ type: "residentKillCancelled" });
      return;
    }
    try {
      await this.killResidentProcessesCore();
    } catch (e) {
      // 掃討が途中で失敗してもタブは閉じる(core の step 1 でモニターは既に停止済みで、
      // 開いたままでも「デバイスモニター」タブは固まるだけ)。失敗はダイアログで知らせる。
      void vscode.window.showErrorMessage(t("monitor.residentKillClose.error", { error: String(e) }));
    }
    // restartAll はしない(「終了して閉じる」なので自動復帰させない)。タブを閉じる。
    // onDidDispose がモニター/配信の停止と後始末を行う(掃討済みなので実質 no-op)。
    this.panel?.dispose();
  }
}
