// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。ライブ操作は独立パネル
// (livePanel.ts)へ分離済み。デバイスタイル右クリック「ライブ操作」だけ openLiveForDevice 経由で連携する。
// MonitorPanelController は以下のサブコントローラを束ねるオーケストレーターで、各サブコントローラは
// 互いを直接参照せず MonitorPanelDeps 経由でのみ連携する:
// - monitorProcessManager.ts の MonitorProcessManager: monitor/host-metrics 常駐子プロセスの起動・停止・再起動
// - monitorProfilesController.ts の MonitorProfilesController: 「プロファイル」タブの一覧post・CRUD・フォームのロード/保存
// - monitorDeviceOps.ts の MonitorDeviceOps: デバイスライフサイクルキュー・device-catalog/installed-devices/create-device
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
import { repairDisplay, repairWifi } from "./adbWifiRepair";
import { type FtesterConfig, resolveAdb, resolveProjectName } from "./config";
import { currentLocale, t } from "./i18n";
import {
  isMonitorFromWebviewMessage,
  type MonitorControlCommand,
  type MonitorDevice,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { MonitorBridgeWatchdog } from "./monitorBridgeWatchdog";
import { MonitorDeviceOps } from "./monitorDeviceOps";
import { MonitorDeviceStreamController } from "./monitorDeviceStreamController";
import { MonitorHealthWatchdog } from "./monitorHealthWatchdog";
import { PANEL_TITLE, renderHtml } from "./monitorHtml";
import { type HostMetricsToWebviewMessage, MonitorProcessManager } from "./monitorProcessManager";
import { MonitorProfilesController } from "./monitorProfilesController";
import { MonitorRecordingsController } from "./monitorRecordingsController";
import { MonitorUpdateController } from "./monitorUpdateController";
import {
  fetchRemoteHosts,
  importRemoteHosts,
  removeRemoteHost,
  type RemoteHostsCliDeps,
} from "./remoteHostsController";
import { diffRemoteHostsForSync, type RemoteHostEntry } from "./remoteRunArgs";
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

const VIEW_TYPE = "ftesterMonitor";

type WipeStatusMessage = Extract<MonitorToWebviewMessage, { readonly type: "wipeStatus" }>;

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(monitorDeviceOps.ts の PipeProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** サブコントローラ間連携の唯一の窓口(サブコントローラ同士は互いを直接参照しない)。 */
export interface MonitorPanelDeps {
  readonly workspaceRoot: string;
  getConfig(): FtesterConfig;
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
  /** 設定タブの「ポーリングモードを使用する」チェックボックスの現在値。true の間は
   * monitorDeviceStreamController.ts がストリーミング開始を抑止しポーリングへフォールバックする
   * (workspaceState の "monitor.pollingMode" を共有する livePanel.ts/monitorLiveController.ts も同様)。 */
  isPollingMode(): boolean;
  /** MonitorProfilesController.postMachineProfileInfoへの委譲。MonitorDeviceOps.runCreateDevice成功時に呼ぶ。 */
  notifyMachineProfilesChanged(): void;
  /** MonitorProfilesController.unregisterDeletedDeviceへの委譲。実体を消したあと、その実体を
   * 参照しているマシンプロファイルから登録も外す(delete-device 成功時)。書き戻せた名前を返す。 */
  unregisterDeletedDevice(
    name: string,
    host: string | undefined,
  ): { readonly machines: readonly string[]; readonly runs: readonly string[] };
  /** MonitorDeviceStreamController.disposeForDeviceNameへの委譲。MonitorDeviceOpsのdevice-downジョブが
   * 実行を開始する時点(simctl/adbで実際に殺す前)で呼び、タイルを即座に切断表示へ倒す。 */
  stopDeviceStreams(name: string, host?: string): void;
  /** MonitorDeviceStreamController.disposeAllForDownへの委譲。MonitorDeviceOpsの一括downジョブの
   * 実行開始時に呼ぶ(stopDeviceStreamsの全台版)。 */
  stopAllStreams(): void;
  /** 生成したソース(絶対パス)を、デバイスモニターの列を避けた列に開く(モニター表示を覆わないため)。 */
  openGeneratedDocument(filePath: string): void;
  /** 録画動画ファイル(絶対パス)を webview から読める URI 文字列に変換する(録画タブ用)。
   * パネル未生成時は null。localResourceRoots(TestProjects/ 配下)の対象外パスを渡さないこと。 */
  videoWebviewUri(absPath: string): string | null;
}

export function registerMonitorPanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  openLiveForDevice: (id: string) => void,
): { relocalize(): void } {
  const controller = new MonitorPanelController(
    workspaceRoot,
    getConfig,
    outputChannel,
    eventBus,
    context.extensionUri,
    context.workspaceState,
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
    // 引数のタブ名は更新通知(updateCheck.ts)が "settings" を渡す。省略時は現在のタブのまま。
    vscode.commands.registerCommand("ftester.showDeviceMonitor", (tab?: string) => controller.show(tab)),
  );

  return { relocalize: () => controller.relocalize() };
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
  /** モニター内タブが「デバイス」か(デバイスタイルが display:none でないか)。
   * webview から devicesTabVisible で届く。初期値 true は起動直後の一瞬だけで、
   * webview の初期 switchTab が必ず正しい値を送ってくる。 */
  private devicesTabVisible = true;

  /** 配信helperを動かすのはパネルが見えていて かつ デバイスタブが開いているときだけ。
   * どちらか一方でも欠けると H.264 のエンコード/デコードが丸ごと無駄になる。 */
  private applyDeviceStreamVisibility(): void {
    this.deviceStream.setVisible(this.panelVisible && this.devicesTabVisible);
  }
  /** 設定タブ「ポーリングモードを使用する」の現在値(ワークスペース単位で永続化)。 */
  private pollingMode: boolean;
  /** デバイスタブのスプリッター位置(タイルペイン高さ px)。未設定(パネル未ドラッグ)は undefined。
   * webview の getState はパネルを閉じると失われるため host 側で永続化する(splitter.js と対の契約)。 */
  private tilePaneHeight: number | undefined;
  /** デバイスタブの auto-fit トグル(タイル高さを全デバイスが横幅に収まる高さへ自動調整)。 */
  private tileAutoFit: boolean;
  /** stopping/rebooting を post 済みで done/failed が未着のデバイス名。runEnded 時、キャンセル等で
   * done/failed が来ないまま残った名前にバッジ固着を防ぐため phase:"done" を post する。 */
  private readonly wipeInProgress = new Set<string>();
  /** 直近に CLI(`ftester api remote-hosts`)から取得・同期した登録簿。setRemoteConfig の
   * 差分計算(diffRemoteHostsForSync)の基準に使うだけで、これ自体が正ではない
   * (docs/remote-runner.md §13「原則」。正は CLI の LocalConfig)。 */
  private lastKnownRemoteHosts: RemoteHostEntry[] = [];

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
    private readonly extensionUri: vscode.Uri,
    private readonly workspaceState: vscode.Memento,
    private readonly openLiveForDevice: (id: string) => void,
  ) {
    this.pollingMode = workspaceState.get<boolean>("monitor.pollingMode", false);
    this.tilePaneHeight = workspaceState.get<number>("monitor.tilePaneHeight");
    // 既定 ON(webview 側 splitter.js の「!== false」と揃える。片方だけ変えない)。
    this.tileAutoFit = workspaceState.get<boolean>("monitor.tileAutoFit", true);
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message),
      isPanelActive: () => this.panel !== undefined,
      writeMonitorControl: (cmd) => this.processManager.writeMonitorControl(cmd),
      notifyMachineProfilesChanged: () => this.profiles.postMachineProfileInfo(),
      unregisterDeletedDevice: (name, host) => this.profiles.unregisterDeletedDevice(name, host),
      openGeneratedDocument: (filePath) => this.openGeneratedDocument(filePath),
      isDeviceStreaming: (deviceId) => this.deviceStream.isStreaming(deviceId),
      getStreamingDeviceIds: () => this.deviceStream.streamingIds(),
      notifyMonitorDevices: (devices) => {
        this.deviceOps.syncCpuRenderNames(devices);
        this.deviceStream.applyDevices(devices);
        this.bridgeWatchdog.observe(devices);
        this.healthWatchdog.observe(devices);
      },
      isPollingMode: () => this.pollingMode,
      stopDeviceStreams: (name, host) => this.deviceStream.disposeForDeviceName(name, host),
      stopAllStreams: () => this.deviceStream.disposeAllForDown(),
      videoWebviewUri: (absPath) =>
        this.panel ? this.panel.webview.asWebviewUri(vscode.Uri.file(absPath)).toString() : null,
    };
    this.deviceStream = new MonitorDeviceStreamController(this.deps);
    this.processManager = new MonitorProcessManager(this.deps);
    this.profiles = new MonitorProfilesController(this.deps);
    this.deviceOps = new MonitorDeviceOps(this.deps);
    this.recordings = new MonitorRecordingsController(this.deps);
    this.update = new MonitorUpdateController({
      workspaceRoot: this.workspaceRoot,
      outputChannel: this.outputChannel,
      post: (message) => this.post(message as never),
    });
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
      if (event.affectsConfiguration("ftester.profile") || event.affectsConfiguration("ftester.project")) {
        this.profiles.postProfileInfo();
        this.restartMonitorIfScopeChanged();
        // ftester.project の変更は対象マシンプロファイル一覧にも影響するため、こちらも最新化する。
        this.profiles.postMachineProfileInfo();
      }
      // 表示フィルタの変更は監視スコープを変えない(モニター再起動なしで即時反映する)。
      // 「起動中のデバイス」選択時は profile と 2 設定同時に変わるため、両分岐が走る。
      if (event.affectsConfiguration("ftester.monitorDeviceFilter")) {
        this.profiles.postProfileInfo();
        this.processManager.repostDevicesWithCurrentFilter();
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
    });
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

  /** ftester.language 変更で extension.ts から呼ぶ。webview.html の再代入は webview を再読込するため
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
  }

  dispose(): void {
    this.profiles.disposePendingNameInput();
    this.unsubscribeBus();
    this.configChangeSubscription.dispose();
    this.profiles.disposeWatchers();
    this.processManager.stopMonitorProcess();
    this.processManager.stopHostMetricsProcess();
    this.deviceStream.dispose();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
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
   * 設定タブのリモートホスト行編集(追加・削除・name/host/dir 変更)を CLI 登録簿へ反映する。
   * lastKnownRemoteHosts との差分だけを送る(diffRemoteHostsForSync)ので、artifacts のみの
   * 変更(hosts は不変)では CLI を叩かない。削除→追加(import は upsert)の順で送ることで、
   * rename(同じ行の name 変更)も「旧名を消し新名を作る」として正しく扱える。
   * CLI 呼び出しが失敗した行は lastKnownRemoteHosts に残らない(=書き込めなかったことが
   * 次に webview へ返す一覧に反映される)。失敗理由は remoteConfig.error に乗せて webview へ返す
   * (settingsTab.js が画面に出す。OUTPUT へのログだけにしない —— 行が黙って消えて見える)。
   */
  private async syncRemoteHostsFromWebview(
    hosts: readonly RemoteHostEntry[],
    artifacts: "collect" | "on-demand",
  ): Promise<void> {
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
    }
    if (upserts.length > 0) {
      const result = await importRemoteHosts(deps, upserts);
      if (result.hosts !== undefined) {
        finalHosts = result.hosts;
      } else {
        error = result.error;
      }
    }
    this.lastKnownRemoteHosts = finalHosts;

    const remoteConfiguration = vscode.workspace.getConfiguration("ftester");
    void remoteConfiguration.update("remote.artifacts", artifacts, vscode.ConfigurationTarget.Global);
    // CLI が返した確定形(書き込めなかった行の除外・machine の実値を含む)で webview を必ず作り直す。
    this.post({ type: "remoteConfig", hosts: finalHosts, artifacts, error });
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
        // 録画タブを開いたまま実行すると、一覧の更新契機(タブ活性化・更新ボタン・再生からの戻る)
        // がどれも起きず、終わった run が出ないままになる。runEnded は NDJSON プロセス終了後
        // (= recordings/index.json 書き出し済み)なので、ここで取り直せば競合しない。
        void this.recordings.refreshSessions();
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
      case "devicesTabVisible":
        this.devicesTabVisible = message.visible;
        this.applyDeviceStreamVisibility();
        return;
      case "refreshResidentProcesses":
        void this.refreshResidentProcesses();
        break;
      case "killAllResidentProcessesAndClose":
        void this.killAllResidentProcessesAndClose();
        break;
      case "deviceOp":
        this.deviceOps.enqueueLifecycleJob({
          kind: "device", name: message.name, op: message.op, host: message.host,
          udid: message.udid, serial: message.serial,
        });
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
      case "machineDevicesSync":
        this.profiles.handleMachineDevicesSync(message);
        break;
      case "machineDeviceRemove":
        void this.profiles.handleMachineDeviceRemove(message.machine, message.devices);
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
        // トグル直後に即時反映する(次の monitorDevices イベント待ちにしない)。ライブ操作パネル
        // (livePanel.ts)は独立プロセスのため、こちらは次のデバイス選択/表示状態変化で追いつく。
        this.deviceStream.reapply();
        break;
      case "setLptHistoryRuns":
        // null = 入力欄が空・不正値 → 設定を消して既定へ戻す(webview 側は入力欄に既定値を入れ直す)
        void vscode.workspace
          .getConfiguration("ftester")
          .update("lptHistoryRuns", message.value ?? undefined, vscode.ConfigurationTarget.Global);
        return;
      case "setLptScheduling":
        // 次の run から効く(実行中の run の順序は変わらない)。CLI へは runHandler.ts が
        // false のとき --no-lpt を渡す。
        void vscode.workspace
          .getConfiguration("ftester")
          .update("lptScheduling", message.value, vscode.ConfigurationTarget.Global);
        return;
      case "setLanguage":
        // ftester.language 設定(Global)を更新。反映(ツリー再翻訳 + 再読み込み案内)は
        // extension.ts の onDidChangeConfiguration ハンドラが担う。
        void vscode.workspace
          .getConfiguration("ftester")
          .update("language", message.value, vscode.ConfigurationTarget.Global);
        break;
      case "setRemoteConfig": {
        const artifacts = message.artifacts === "on-demand" ? "on-demand" : "collect";
        void this.syncRemoteHostsFromWebview(message.hosts, artifacts);
        break;
      }
      case "setTilePaneHeight":
        this.tilePaneHeight = message.value;
        void this.workspaceState.update("monitor.tilePaneHeight", message.value);
        break;
      case "setTileAutoFit":
        this.tileAutoFit = message.value;
        void this.workspaceState.update("monitor.tileAutoFit", message.value);
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
      case "recordingsRefresh":
        void this.recordings.refreshSessions();
        break;
      case "recordingsOpen":
        void this.recordings.openSession(message.project, message.runID);
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
    this.post({ type: "pollingMode", value: this.pollingMode });
    this.post({
      type: "lptScheduling",
      value: vscode.workspace.getConfiguration("ftester").get<boolean>("lptScheduling", true),
    });
    // default は設定タブの初期値・空欄時の戻り先に使う(Swift 側 LPTOrdering.defaultHistoryRuns と
    // package.json の既定値に一致させること。lptDefaultSync.test.mjs が検証)
    this.post({
      type: "lptHistoryRuns",
      value: vscode.workspace.getConfiguration("ftester").get<number>("lptHistoryRuns", 5),
      default: 5,
    });
    this.post({
      type: "language",
      value: vscode.workspace.getConfiguration("ftester").get<"auto" | "ja" | "en">("language", "auto"),
    });
    {
      // hosts の正は CLI の LocalConfig(docs/remote-runner.md §13「原則」)。artifacts は
      // 引き続き VSCode 設定(config.ts の readConfig と同じ既定値)。fetch は非同期なので
      // fire-and-forget で送り直す(失敗しても他の初期化を止めない。update-check と同じ方針)。
      const remoteConfiguration = vscode.workspace.getConfiguration("ftester");
      const artifacts =
        remoteConfiguration.get<string>("remote.artifacts", "collect") === "on-demand" ? "on-demand" : "collect";
      void fetchRemoteHosts(this.remoteHostsDeps()).then((result) => {
        this.lastKnownRemoteHosts = result.hosts ?? [];
        this.post({ type: "remoteConfig", hosts: this.lastKnownRemoteHosts, artifacts });
      });
    }
    if (this.tilePaneHeight !== undefined) {
      this.post({ type: "tilePaneHeight", value: this.tilePaneHeight });
    }
    // auto-fit は tilePaneHeight より後に送る(ON なら高さは復元値ではなく再計算で決まる)。
    this.post({ type: "tileAutoFit", value: this.tileAutoFit });
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

  // 掃討本体(確認ダイアログ・掃討後の後始末は killAllResidentProcessesAndClose が持つ)。
  private async killResidentProcessesCore(): Promise<void> {
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
    for (const p of remaining) {
      if (p.pid <= 0 || p.pid === process.pid || p.type === "emulator" || p.type === "mcp") {
        continue;
      }
      if (!this.isWorkspaceOwned(p.command)) {
        continue;
      }
      try {
        process.kill(p.pid, "SIGKILL");
      } catch (e) {
        if ((e as NodeJS.ErrnoException)?.code !== "ESRCH") {
          this.outputChannel.appendLine(
            `[ftester] ${t("monitor.log.residentKillFailed", { pid: p.pid, error: String(e) })}`,
          );
        }
      }
    }
  }

  private async killAllResidentProcessesAndClose(): Promise<void> {
    try {
      await this.killResidentProcessesCore();
    } catch (e) {
      // 掃討が途中で失敗してもタブは閉じる(core の step 1 でモニターは既に停止済みで、
      // 開いたままでもデバイスタブは固まるだけ)。失敗はダイアログで知らせる。
      void vscode.window.showErrorMessage(t("monitor.residentKillClose.error", { error: String(e) }));
    }
    // restartAll はしない(「終了して閉じる」なので自動復帰させない)。タブを閉じる。
    // onDidDispose がモニター/配信の停止と後始末を行う(掃討済みなので実質 no-op)。
    this.panel?.dispose();
  }
}
