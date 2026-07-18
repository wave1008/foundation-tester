// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。ライブ操作は独立パネル
// (livePanel.ts)へ分離済み。デバイスタイル右クリック「ライブ操作」だけ openLiveForDevice 経由で連携する。
// MonitorPanelController は以下のサブコントローラを束ねるオーケストレーターで、各サブコントローラは
// 互いを直接参照せず MonitorPanelDeps 経由でのみ連携する:
// - monitorProcessManager.ts の MonitorProcessManager: monitor/host-metrics 常駐子プロセスの起動・停止・再起動
// - monitorProfilesController.ts の MonitorProfilesController: 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存
// - monitorDeviceOps.ts の MonitorDeviceOps: デバイスライフサイクルキュー・device-catalog/installed-devices/create-device
// - monitorExploreController.ts の MonitorExploreController: 「FM探索」タブの list-devices・`api explore` 実行
// - monitorDeviceStreamController.ts の MonitorDeviceStreamController: デバイスタイルの画面ストリーミング
//   (iOS/Android共通の StreamPipeline)管理。connected な monitorFrame ポーリングとの間引き調停は
//   MonitorProcessManager 側。
// - monitorHtml.ts: webview の HTML 本文(renderHtml/generateNonce/PANEL_TITLE)
// - monitorModel.ts / runLaneModel.ts / liveModel.ts: vscode 非依存の純粋関数(検証・変換・状態遷移)
//
// 契約・不変条件:
// - monitor プロセス、および devicesUp/devicesDown・device-catalog 等の短命 CLI 呼び出しは
//   cli.ts の FtesterCli(直列キュー)を使わず直接 spawn する。monitor は接続中ずっと動くプロセスなので、
//   キューに載せると以後の CLI 呼び出しが永久にブロックされるため。
// - 子プロセス終了は SIGTERM→2秒後もまだ生きていれば SIGKILL(cli.ts の cancelCurrent() と同じ方針)。
// - ログレーン用の RunEventBus は runHandler.ts の実行と同一インスタンス(extension.ts から注入)。
//   デバイスタイルとログレーンは device id / worker id が同一規則のため突合できる。
// - host-metrics プロセスはプロファイル/プロジェクトに依存しないため、監視対象切り替え
//   (restartMonitorIfScopeChanged 等)では再起動しない。

import { type ChildProcessByStdio, execFile, spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import type { Readable } from "node:stream";
import * as vscode from "vscode";
import { repairWifi } from "./adbWifiRepair";
import type { FtesterCli } from "./cli";
import { type FtesterConfig, readRunProfileDeviceNames, resolveAdb, resolveProjectName } from "./config";
import { isExploreWebviewEnvelope, type ExploreToWebviewEnvelope } from "./exploreModel";
import { currentLocale, t } from "./i18n";
import {
  devicesToShutdownOnScopeChange,
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  type MonitorDevice,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { MonitorBridgeWatchdog } from "./monitorBridgeWatchdog";
import { MonitorDeviceOps } from "./monitorDeviceOps";
import { MonitorDeviceStreamController } from "./monitorDeviceStreamController";
import { MonitorExploreController } from "./monitorExploreController";
import { MonitorHealthWatchdog } from "./monitorHealthWatchdog";
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
import { TYPE_ORDER, parseAndroidBridges, parseResidentProcesses, type ResidentProcess } from "./residentProcesses";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  isAnyLaneRunning,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";
import type { FtesterTestTree } from "./testTree";

const VIEW_TYPE = "ftesterMonitor";

type WipeStatusMessage = Extract<MonitorToWebviewMessage, { readonly type: "wipeStatus" }>;

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(monitorDeviceOps.ts の PipeProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** サブコントローラ間連携の唯一の窓口(サブコントローラ同士は互いを直接参照しない)。 */
export interface MonitorPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(
    message:
      | MonitorToWebviewMessage
      | RunLaneToWebviewMessage
      | HostMetricsToWebviewMessage
      | ExploreToWebviewEnvelope,
  ): void;
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
  /** 設定タブの「ポーリングモードを使用する」チェックボックスの現在値。true の間は
   * monitorDeviceStreamController.ts がストリーミング開始を抑止しポーリングへフォールバックする
   * (workspaceState の "monitor.pollingMode" を共有する livePanel.ts/monitorLiveController.ts も同様)。 */
  isPollingMode(): boolean;
  /** MonitorProfilesController.postMachineProfileInfoへの委譲。MonitorDeviceOps.runCreateDevice成功時に呼ぶ。 */
  notifyMachineProfilesChanged(): void;
  /** MonitorDeviceStreamController.disposeForDeviceNameへの委譲。MonitorDeviceOpsのdevice-downジョブが
   * 実行を開始する時点(simctl/adbで実際に殺す前)で呼び、タイルを即座に切断表示へ倒す。 */
  stopDeviceStreams(name: string): void;
  /** MonitorDeviceStreamController.disposeAllForDownへの委譲。MonitorDeviceOpsの一括downジョブの
   * 実行開始時に呼ぶ(stopDeviceStreamsの全台版)。 */
  stopAllStreams(): void;
  /** 生成したソース(絶対パス)を、デバイスモニターの列を避けた列に開く(モニター表示を覆わないため)。
   * explore コントローラの生成完了時に使う。 */
  openGeneratedDocument(filePath: string): void;
}

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  cli: FtesterCli,
  testTree: FtesterTestTree,
  openLiveForDevice: (id: string) => void,
): void {
  const controller = new MonitorPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
    context.workspaceState,
    cli,
    testTree,
    openLiveForDevice,
  );
  // TEST EXPLORER タイトルの view/title ボタンはペイン非フォーカス時に隠れる。
  // フォーカスに依存しない常時表示の導線としてステータスバーへ常駐させる。
  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  statusItem.text = t("monitor.statusBar.label");
  statusItem.tooltip = t("monitor.statusBar.tooltip");
  statusItem.command = "ftester.showDeviceMonitor";
  statusItem.show();

  context.subscriptions.push(
    controller,
    statusItem,
    vscode.commands.registerCommand("ftester.showDeviceMonitor", () => controller.show()),
    vscode.commands.registerCommand("ftester.explore", () => controller.show("explore")),
  );
}

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: MonitorPanelDeps;
  private readonly processManager: MonitorProcessManager;
  private readonly profiles: MonitorProfilesController;
  private readonly deviceOps: MonitorDeviceOps;
  private readonly bridgeWatchdog: MonitorBridgeWatchdog;
  private readonly healthWatchdog: MonitorHealthWatchdog;
  private readonly explore: MonitorExploreController;
  private readonly deviceStream: MonitorDeviceStreamController;

  /** パネル再作成時にhydrateLaneUi()で流し込むため、実行を跨いで保持する。 */
  private readonly laneState = createRunLaneState();
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;
  private readonly configChangeSubscription: vscode.Disposable;
  /** show(tab) が新規作成時に指定したタブ。sendInitialState() で switchTab を post した後クリアする
   * (html設定直後の postMessage は webview 側リスナー登録前に届き握りつぶされるため。show() 参照)。 */
  private pendingInitialTab: string | undefined;
  /** 設定タブ「ポーリングモードを使用する」の現在値(ワークスペース単位で永続化)。 */
  private pollingMode: boolean;
  /** デバイスタブのスプリッター位置(タイルペイン高さ px)。未設定(パネル未ドラッグ)は undefined。
   * webview の getState はパネルを閉じると失われるため host 側で永続化する(splitter.js と対の契約)。 */
  private tilePaneHeight: number | undefined;
  /** stopping/rebooting を post 済みで done/failed が未着のデバイス名。runEnded 時、キャンセル等で
   * done/failed が来ないまま残った名前にバッジ固着を防ぐため phase:"done" を post する。 */
  private readonly wipeInProgress = new Set<string>();

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
    private readonly workspaceState: vscode.Memento,
    cli: FtesterCli,
    testTree: FtesterTestTree,
    private readonly openLiveForDevice: (id: string) => void,
  ) {
    this.pollingMode = workspaceState.get<boolean>("monitor.pollingMode", false);
    this.tilePaneHeight = workspaceState.get<number>("monitor.tilePaneHeight");
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
      isPanelActive: () => this.panel !== undefined,
      writeMonitorControl: (cmd) => this.processManager.writeMonitorControl(cmd),
      notifyMachineProfilesChanged: () => this.profiles.postMachineProfileInfo(),
      openGeneratedDocument: (filePath) => this.openGeneratedDocument(filePath),
      isDeviceStreaming: (deviceId) => this.deviceStream.isStreaming(deviceId),
      getStreamingDeviceIds: () => this.deviceStream.streamingIds(),
      notifyMonitorDevices: (devices) => {
        this.deviceStream.applyDevices(devices);
        this.bridgeWatchdog.observe(devices);
        this.healthWatchdog.observe(devices);
      },
      isPollingMode: () => this.pollingMode,
      stopDeviceStreams: (name) => this.deviceStream.disposeForDeviceName(name),
      stopAllStreams: () => this.deviceStream.disposeAllForDown(),
    };
    this.deviceStream = new MonitorDeviceStreamController(this.deps);
    this.processManager = new MonitorProcessManager(this.deps);
    this.profiles = new MonitorProfilesController(this.deps);
    this.deviceOps = new MonitorDeviceOps(this.deps);
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
      restartStream: (name) => this.deviceStream.restartForDeviceName(name),
      isAutoRepairEnabled: () => this.getConfig().autoRepairDeviceHealth,
      isDeviceLifecycleQueueBusy: () => this.deviceOps.isQueueBusy(),
    });
    this.explore = new MonitorExploreController(this.deps, cli, workspaceState, () => void testTree.refresh());

    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
    this.configChangeSubscription = vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("ftester.profile") || event.affectsConfiguration("ftester.project")) {
        this.profiles.postProfileInfo();
        this.restartMonitorIfScopeChanged();
        // ftester.project の変更は対象マシンプロファイル一覧にも影響するため、こちらも最新化する。
        this.profiles.postMachineProfileInfo();
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
    this.enqueueShutdownOutsideNewScope(resolution.project, config.profile);
    this.processManager.restartMonitorProcess();
  }

  /**
   * 切り替え先プロファイルに定義されていない稼働中デバイスをdownする(定義済みデバイスは
   * 稼働中でもそのまま — 自動起動はしない)。newProfileが空、またはreadRunProfileDeviceNamesが
   * nullを返す場合はdevicesToShutdownOnScopeChange(devices, null)が空配列を返すため何もしない。
   */
  private enqueueShutdownOutsideNewScope(project: string, newProfile: string): void {
    const newScopeNames =
      newProfile === "" ? null : readRunProfileDeviceNames(this.workspaceRoot, project, newProfile);
    const targets = devicesToShutdownOnScopeChange(this.processManager.lastKnownDevices, newScopeNames);
    if (targets.length === 0) {
      return;
    }
    this.outputChannel.appendLine(
      `[ftester] ${t("monitor.log.stoppingOutOfScopeDevices", { names: targets.join(", ") })}`,
    );
    for (const name of targets) {
      this.deviceOps.enqueueLifecycleJob({ kind: "device", name, op: "down" });
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
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, "media")],
    });
    this.panel = panel;
    panel.webview.html = renderHtml(panel.webview, this.extensionUri);

    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    // パネルが他タブの裏に隠れている間はストリーミング helper を止める(isPanelActive とは別軸:
    // こちらは実際の表示可否。再表示後は次の monitorDevices イベントで再構築される)。
    panel.onDidChangeViewState((event) => this.deviceStream.setVisible(event.webviewPanel.visible));
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.processManager.stopMonitorProcess();
      this.processManager.stopHostMetricsProcess();
      this.deviceStream.dispose();
    });

    this.pendingInitialTab = initialTab;
    this.processManager.startAll();
    // 初期状態はここで送らない: html設定直後のpostMessageはwebview側のmessageリスナー登録前に
    // 届き握りつぶされる(VS Code既知のレース)。webviewからの"ready"を受けてsendInitialState()で送る。
  }

  dispose(): void {
    this.profiles.disposePendingNameInput();
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profiles.disposeWatchers();
    this.processManager.stopMonitorProcess();
    this.processManager.stopHostMetricsProcess();
    this.explore.dispose();
    this.deviceStream.dispose();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(
    message:
      | MonitorToWebviewMessage
      | RunLaneToWebviewMessage
      | HostMetricsToWebviewMessage
      | ExploreToWebviewEnvelope,
  ): void {
    void this.panel?.webview.postMessage(message);
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
        this.laneSectionVisible = true;
        this.post({ type: "laneSectionVisible", visible: true });
        break;
      case "event":
        if (message.event.kind === "wipeStatus") {
          this.handleWipeStatusEvent(message.event.device, message.event.phase);
        }
        for (const action of reduceLaneEvent(this.laneState, message.event, Date.now())) {
          this.post({ type: "runEvent", action });
        }
        break;
      case "runEnded":
        // runFinished未受信のまま終了(異常終了/キャンセル)した場合の後始末。正常終了時は無害(no-op)。
        for (const action of forceEndRunLaneState(this.laneState)) {
          this.post({ type: "runEvent", action });
        }
        for (const name of this.wipeInProgress) {
          this.post({ type: "wipeStatus", name, phase: "done" });
        }
        this.wipeInProgress.clear();
        break;
    }
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
    if (isExploreWebviewEnvelope(message)) {
      this.explore.handleWebviewMessage(message.message);
      return;
    }
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
        this.deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "down" });
        break;
      case "restartMonitor":
        // ストリームを先に作り直す: streamingIds をクリアしてから monitor を再起動させることで、
        // 新モニターへの stale な suppressFrames 再送を防ぎ、新キーフレームでタイル餓死を回避する
        // (monitorDeviceStreamController.restartAllStreams 参照)。
        this.deviceStream.restartAllStreams();
        this.processManager.restartAll();
        break;
      case "refreshResidentProcesses":
        void this.refreshResidentProcesses();
        break;
      case "killAllResidentProcesses":
        void this.killAllResidentProcesses();
        break;
      case "deviceOp":
        this.deviceOps.enqueueLifecycleJob({ kind: "device", name: message.name, op: message.op });
        break;
      case "openLiveForDevice":
        this.openLiveForDevice(message.id);
        break;
      case "deviceRestartGpu":
        this.deviceOps.restartWithGpu(message.name);
        break;
      case "devicesRestartGpu":
        this.deviceOps.restartWithGpuBatch(message.names);
        break;
      case "selectProfile":
        this.profiles.selectProfile(message.profile);
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
      case "machineProfileRefresh":
        this.profiles.postMachineProfileInfo();
        break;
      case "machineProfileAdd":
        void this.profiles.handleMachineProfileAdd();
        break;
      case "machineProfileCopy":
        void this.profiles.handleMachineProfileCopy(message.machine);
        break;
      case "machineProfileDelete":
        void this.profiles.handleMachineProfileDelete(message.machine);
        break;
      case "machineProfileRename":
        void this.profiles.handleMachineProfileRename(message.machine);
        break;
      case "deviceCatalogRequest":
        this.deviceOps.runDeviceCatalog();
        break;
      case "createDevice":
        this.deviceOps.runCreateDevice(message);
        break;
      case "installedDevicesRequest":
        this.deviceOps.runInstalledDevices();
        break;
      case "machineDevicesSync":
        this.profiles.handleMachineDevicesSync(message);
        break;
      case "machineDeviceRemove":
        void this.profiles.handleMachineDeviceRemove(message.machine, message.names);
        break;
      case "machineDeviceUpdate":
        this.profiles.handleMachineDeviceUpdate(message);
        break;
      case "runProfileLoad":
        this.profiles.handleRunProfileLoad(message.profile);
        break;
      case "runProfileSave":
        this.profiles.handleRunProfileSave(message);
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
      case "setPollingMode":
        this.pollingMode = message.value;
        void this.workspaceState.update("monitor.pollingMode", message.value);
        // トグル直後に即時反映する(次の monitorDevices イベント待ちにしない)。ライブ操作パネル
        // (livePanel.ts)は独立プロセスのため、こちらは次のデバイス選択/表示状態変化で追いつく。
        this.deviceStream.reapply();
        break;
      case "setLanguage":
        // ftester.language 設定(Global)を更新。反映(ツリー再翻訳 + 再読み込み案内)は
        // extension.ts の onDidChangeConfiguration ハンドラが担う。
        void vscode.workspace
          .getConfiguration("ftester")
          .update("language", message.value, vscode.ConfigurationTarget.Global);
        break;
      case "setTilePaneHeight":
        this.tilePaneHeight = message.value;
        void this.workspaceState.update("monitor.tilePaneHeight", message.value);
        break;
      case "streamRendered":
        // webview がストリームフレームを描画できた ack。これを受けて初めてポーリングを間引く
        // (契約: monitorDeviceStreamController.ts 冒頭)
        if (message.device) {
          this.deviceStream.noteStreamRendered(message.device);
        }
        break;
      case "streamStall":
        if (message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: ${t("monitor.log.streamStallRestart")}`,
          );
          this.deviceStream.restartDevice(message.device);
        }
        break;
      case "codecError":
        if (message.scope === "tile" && message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: ${t("monitor.log.codecFallbackMjpeg")}`,
          );
          this.deviceStream.fallbackToMjpeg(message.device);
        }
        break;
    }
  }

  /**
   * webviewからの"ready"を受けて初期状態をまとめて送る。readyはwebview再読込のたびに再送
   * されうるため、ここで呼ぶ各処理は冪等であること(いずれもwebview側で上書き描画するだけ)。
   */
  private sendInitialState(): void {
    this.hydrateLaneUi();
    this.profiles.postProfileInfo();
    this.profiles.postMachineProfileInfo();
    // webview再読込がジョブ実行中に起きた場合にボタン無効状態・タイルのバッジを復元するため。
    this.deviceOps.resendQueueStatus();
    this.explore.sendInitialState();
    this.post({ type: "pollingMode", value: this.pollingMode });
    this.post({
      type: "language",
      value: vscode.workspace.getConfiguration("ftester").get<"auto" | "ja" | "en">("language", "auto"),
    });
    if (this.tilePaneHeight !== undefined) {
      this.post({ type: "tilePaneHeight", value: this.tilePaneHeight });
    }
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
  // 張られているかは `.ftester/bridge-<port>.inapp`("<udid> <bundleID>" の1行)に記録される。
  // 実行のたびに変わるのでキャッシュせず毎回読む(小さいファイル数個)。
  private async readInappBridges(): Promise<Map<string, string>> {
    const dir = path.join(this.workspaceRoot, ".ftester");
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
      execFile(adb, args, { timeout: 4000 }, (err, out) => {
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
        execFile("ps", ["-axo", "pid=,ppid=,state=,command="], { maxBuffer: 8 * 1024 * 1024 }, (err, out) => {
          resolve(err ? "" : out);
        });
      }),
      this.readInappBridges(),
      this.listAndroidBridges(),
    ]);
    // config の binaryPath 配下(このリポジトリのビルド成果物)は名前を問わず ftester 由来として拾う。
    const binaryDir = path.dirname(this.getConfig().binaryPath);
    // 表示・掃除の対象外を取得段階で除外する: Android エミュ本体(qemu、デバイスタブの領域)と
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
        { maxBuffer: 8 * 1024 * 1024, timeout: 8000 },
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

  /** ftester CLI を1回実行して完了(または 120s タイムアウト)まで待つ。exit code は問わず
   *  resolve する(掃除の一手段のため、失敗しても後段の SIGKILL 掃討に委ねて続行する)。 */
  private runFtester(args: string[]): Promise<void> {
    return new Promise<void>((resolve) => {
      const tag = args.join(" ");
      let proc: PipeProcess;
      try {
        proc = spawn(this.getConfig().binaryPath, args, {
          cwd: this.workspaceRoot,
          shell: false,
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e) {
        this.outputChannel.appendLine(`[ftester] ${tag} ${t("monitor.log.launchFailed", { error: String(e) })}`);
        resolve();
        return;
      }
      const onLine = (stream: string, chunk: Buffer): void => {
        for (const raw of chunk.toString("utf8").split("\n")) {
          const t = raw.trim();
          if (t) {
            this.outputChannel.appendLine(`[${tag} ${stream}] ${t}`);
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
        resolve();
      }, 120000);
      proc.on("close", () => {
        clearTimeout(timer);
        resolve();
      });
      proc.on("error", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  // SIGKILL 掃討の対象を「この workspace 由来」に限定する判定。実行時の workspaceRoot / binaryDir を
  // 基準にするため VSIX にパスは焼き込まれない(配布先では各自の開いている workspace が基準になる)。
  // iOS ブリッジは xctestrun が <workspaceRoot>/.ftester 配下、ftester CLI/mcp/stream/run は binaryDir
  // から起動されるため一致する。sim-runner / in-app はコマンドに workspace パスを持たない(sim
  // コンテナ内)ため一致せず、それらは step 2 の bridge down --all に委ねる。
  private isWorkspaceOwned(command: string): boolean {
    if (command.includes(this.workspaceRoot)) {
      return true;
    }
    const binaryDir = path.dirname(this.getConfig().binaryPath);
    return path.isAbsolute(binaryDir) && command.includes(binaryDir);
  }

  private async killAllResidentProcesses(): Promise<void> {
    const CONFIRM = t("monitor.residentKill.confirmButton");
    const choice = await vscode.window.showWarningMessage(
      t("monitor.residentKill.warningBody"),
      { modal: true },
      CONFIRM,
    );
    if (choice !== CONFIRM) {
      this.post({ type: "residentKillResult", status: "cancelled" });
      return;
    }
    try {
      // 1) 自分の常駐子を respawn 抑止して停止(生 SIGKILL による respawn churn を防ぐため先に)。
      this.deviceStream.disposeAllForDown();
      this.processManager.stopMonitorProcess();
      this.processManager.stopHostMetricsProcess();
      // 2) iOS ブリッジをシミュレータ本体を残してクリーン停止(xcuitest+inapp。pid/inapp ファイル基準で
      //    SIGTERM→simctl terminate。simctl shutdown はしない=デバイスタブの領域)。
      await this.runFtester(["bridge", "down", "--all"]);
      // 3) Android ブリッジを am force-stop + adb forward --remove で停止(qemu=エミュレータ本体は残す)。
      //    adb 未検出環境ではスキップ(出力ノイズを避ける)。
      if (resolveAdb()) {
        await this.runFtester(["bridge", "down", "--platform", "android"]);
      }
      // 4) 残余のホスト常駐を SIGKILL 掃討。この workspace 由来のものだけに限定する
      //    (machine-wide の巻き込み・別 repo の同種プロセスへの誤爆を避ける)。除外:
      //    Android エミュ本体(emulator)/ PID 無しの情報行 / MCP サーバ(mcp)/ 拡張ホスト自身。
      const remaining = await this.listResidentProcesses();
      let killed = 0;
      for (const p of remaining) {
        if (p.pid <= 0 || p.pid === process.pid || p.type === "emulator" || p.type === "mcp") {
          continue;
        }
        if (!this.isWorkspaceOwned(p.command)) {
          continue;
        }
        try {
          process.kill(p.pid, "SIGKILL");
          killed++;
        } catch (e) {
          if ((e as NodeJS.ErrnoException)?.code !== "ESRCH") {
            this.outputChannel.appendLine(
              `[ftester] ${t("monitor.log.residentKillFailed", { pid: p.pid, error: String(e) })}`,
            );
          }
        }
      }
      this.post({ type: "residentKillResult", status: "done", killed });
    } catch (e) {
      this.post({ type: "residentKillResult", status: "error", error: String(e) });
    } finally {
      // step 1 でモニター/host-metrics を止めている。デバイスタブはモニターが供給する状態でしか
      // タイルを更新できず、止めたままだと「シャットダウン中」等で固まる。掃討後に自動再起動して
      // 復帰させる(手動「モニター再起動」不要)。restartAll は失敗カウンタもリセットする。
      this.processManager.restartAll();
      await this.refreshResidentProcesses();
    }
  }
}
