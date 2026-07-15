// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`/`ftester.showLiveControl`)。
// MonitorPanelController は以下のサブコントローラを束ねるオーケストレーターで、各サブコントローラは
// 互いを直接参照せず MonitorPanelDeps 経由でのみ連携する:
// - monitorProcessManager.ts の MonitorProcessManager: monitor/host-metrics 常駐子プロセスの起動・停止・再起動
// - monitorProfilesController.ts の MonitorProfilesController: 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存
// - monitorDeviceOps.ts の MonitorDeviceOps: デバイスライフサイクルキュー・device-catalog/installed-devices/create-device
// - monitorLiveController.ts の MonitorLiveController: 「ライブ操作」タブの list-devices・live serve プロセス管理
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

import * as vscode from "vscode";
import type { FtesterCli } from "./cli";
import { type FtesterConfig, readRunProfileDeviceNames, resolveProjectName } from "./config";
import { isExploreWebviewEnvelope, type ExploreToWebviewEnvelope } from "./exploreModel";
import { isLiveWebviewEnvelope, type LiveToWebviewEnvelope } from "./liveModel";
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
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { MonitorLiveController } from "./monitorLiveController";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
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
      | LiveToWebviewEnvelope
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
   * monitorLiveController.ts/monitorDeviceStreamController.ts の両方がストリーミング開始を
   * 抑止しポーリングへフォールバックする(iOS/Android・ライブ操作タブ/デバイスタイル共通)。 */
  isPollingMode(): boolean;
  /** MonitorProfilesController.postMachineProfileInfoへの委譲。MonitorDeviceOps.runCreateDevice成功時に呼ぶ。 */
  notifyMachineProfilesChanged(): void;
  /** 生成したソース(絶対パス)を、デバイスモニターの列を避けた列に開く(モニター表示を覆わないため)。
   * live/explore 両コントローラの生成完了時に使う。 */
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
  );
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showDeviceMonitor", () => controller.show()),
    vscode.commands.registerCommand("ftester.showLiveControl", () => controller.show("live")),
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
  private readonly live: MonitorLiveController;
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

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
    private readonly workspaceState: vscode.Memento,
    cli: FtesterCli,
    testTree: FtesterTestTree,
  ) {
    this.pollingMode = workspaceState.get<boolean>("monitor.pollingMode", false);
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
      },
      isPollingMode: () => this.pollingMode,
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
    this.live = new MonitorLiveController(this.deps, cli, () => void testTree.refresh());
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
      `[ftester] プロファイル切り替えに伴い監視対象外のデバイスを停止します: ${targets.join(", ")}`,
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
      this.live.stopProcesses();
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
    this.live.dispose();
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
      | LiveToWebviewEnvelope
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
        for (const action of reduceLaneEvent(this.laneState, message.event, Date.now())) {
          this.post({ type: "runEvent", action });
        }
        break;
      case "runEnded":
        // runFinished未受信のまま終了(異常終了/キャンセル)した場合の後始末。正常終了時は無害(no-op)。
        for (const action of forceEndRunLaneState(this.laneState)) {
          this.post({ type: "runEvent", action });
        }
        break;
    }
  }

  private handleWebviewMessage(message: unknown): void {
    if (isLiveWebviewEnvelope(message)) {
      this.live.handleWebviewMessage(message.message);
      return;
    }
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
        this.deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "up" });
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
      case "deviceOp":
        this.deviceOps.enqueueLifecycleJob({ kind: "device", name: message.name, op: message.op });
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
        // トグル直後に両供給元へ即時反映する(次のデバイス選択/monitorDevicesイベント待ちにしない)。
        this.live.refreshFrameSource();
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
          this.outputChannel.appendLine(
            "[live-stream] キーフレーム未受信のままのためヘルパーを再起動します。",
          );
          this.live.restartStream();
        } else if (message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: キーフレーム未受信のままのためヘルパーを再起動します。`,
          );
          this.deviceStream.restartDevice(message.device);
        }
        break;
      case "codecError":
        if (message.scope === "tile" && message.device) {
          this.outputChannel.appendLine(
            `[monitor-stream] ${message.device}: WebCodecs 未対応/デコード失敗のため mjpeg へフォールバックします。`,
          );
          this.deviceStream.fallbackToMjpeg(message.device);
        } else if (message.scope === "live") {
          this.outputChannel.appendLine("[live-stream] WebCodecs 未対応/デコード失敗のため mjpeg へフォールバックします。");
          this.live.fallbackToMjpeg();
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
    if (this.pendingInitialTab) {
      this.post({ type: "switchTab", tab: this.pendingInitialTab });
      this.pendingInitialTab = undefined;
    }
  }
}
