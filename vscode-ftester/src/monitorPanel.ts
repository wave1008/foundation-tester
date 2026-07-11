// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。MonitorPanelController は
// 以下のサブコントローラを束ねるオーケストレーターで、各サブコントローラは互いを直接参照せず
// MonitorPanelDeps 経由でのみ連携する:
// - monitorProcessManager.ts の MonitorProcessManager: monitor/host-metrics 常駐子プロセスの起動・停止・再起動
// - monitorProfilesController.ts の MonitorProfilesController: 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存
// - monitorDeviceOps.ts の MonitorDeviceOps: デバイスライフサイクルキュー・device-catalog/installed-devices/create-device
// - monitorHtml.ts: webview の HTML 本文(renderHtml/generateNonce/PANEL_TITLE)
// - monitorModel.ts / runLaneModel.ts: vscode 非依存の純粋関数(検証・変換・状態遷移)
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
import { type FtesterConfig, readRunProfileDeviceNames, resolveProjectName } from "./config";
import {
  devicesToShutdownOnScopeChange,
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { MonitorDeviceOps } from "./monitorDeviceOps";
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import {
  createRunLaneState,
  forceEndRunLaneState,
  reduceLaneEvent,
  snapshotRunLaneState,
  type RunLaneToWebviewMessage,
} from "./runLaneModel";

const VIEW_TYPE = "ftesterMonitor";

/** 3サブコントローラ間連携の唯一の窓口(サブコントローラ同士は互いを直接参照しない)。 */
export interface MonitorPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage): void;
  /** パネル表示中か。MonitorProcessManager.scheduleHostMetricsRestart()の5秒後再起動タイマーが使う。 */
  isPanelActive(): boolean;
  /** MonitorProcessManager.writeMonitorControlへの委譲。MonitorDeviceOpsのdown系ジョブ前後で呼ぶ。 */
  writeMonitorControl(cmd: MonitorControlCommand): void;
  /** MonitorProfilesController.postMachineProfileInfoへの委譲。MonitorDeviceOps.runCreateDevice成功時に呼ぶ。 */
  notifyMachineProfilesChanged(): void;
}

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

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: MonitorPanelDeps;
  private readonly processManager: MonitorProcessManager;
  private readonly profiles: MonitorProfilesController;
  private readonly deviceOps: MonitorDeviceOps;

  /** パネル再作成時にhydrateLaneUi()で流し込むため、実行を跨いで保持する。 */
  private readonly laneState = createRunLaneState();
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;
  private readonly configChangeSubscription: vscode.Disposable;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
  ) {
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
      isPanelActive: () => this.panel !== undefined,
      writeMonitorControl: (cmd) => this.processManager.writeMonitorControl(cmd),
      notifyMachineProfilesChanged: () => this.profiles.postMachineProfileInfo(),
    };
    this.processManager = new MonitorProcessManager(this.deps);
    this.profiles = new MonitorProfilesController(this.deps);
    this.deviceOps = new MonitorDeviceOps(this.deps);

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
      this.processManager.stopMonitorProcess();
      this.processManager.stopHostMetricsProcess();
    });

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
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(
    message: MonitorToWebviewMessage | RunLaneToWebviewMessage | HostMetricsToWebviewMessage,
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
  }
}
