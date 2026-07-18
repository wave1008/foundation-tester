// livePanel.ts
// 独立ライブ操作パネルの WebviewPanel(コマンド `ftester.showLiveControl`)。ロジック本体は
// monitorLiveController.ts の MonitorLiveController(LiveDeps 経由で疎結合)、HTML 生成は
// livePanelHtml.ts。デバイスモニター(monitorPanel.ts)からは独立した別パネル・別webviewだが、
// polling モード設定(workspaceState の "monitor.pollingMode")だけは共有する。
//
// 開き方は2経路:
// - 手動: ftester.showLiveControl コマンド(ステータスバー常駐ボタンからも)。既存パネルなら
//   reveal のうえ、選択中デバイスへの再バインドを促す(refreshDevicesFromHost)。
// - 自動: RunEventBus の runStarted(非 dry-run、ftester.liveControlOnRun 設定が true の間)。
//   デバイスタイル右クリック「ライブ操作」(monitorPanel.ts の openLiveForDevice 経由)は
//   openForDevice() から呼ばれ、対象デバイスを選択させる。

import * as vscode from "vscode";
import type { FtesterCli } from "./cli";
import type { FtesterConfig } from "./config";
import type { LiveDeps } from "./liveDeps";
import { isLiveWebviewEnvelope } from "./liveModel";
import { LIVE_PANEL_TITLE, renderLiveHtml } from "./livePanelHtml";
import type { LiveRunTarget } from "./liveRunTarget";
import { MonitorLiveController } from "./monitorLiveController";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import type { FtesterTestTree } from "./testTree";

const VIEW_TYPE = "ftesterLiveControl";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

class LivePanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private readonly deps: LiveDeps;
  private readonly live: MonitorLiveController;
  private readonly unsubscribeBus: () => void;
  /** openForDevice() がパネル新規作成と同時に呼ばれた場合の openDevice 送信保留先。html 設定直後の
   * postMessage は webview 側 message リスナー登録前に届き握りつぶされる(VS Code既知のレース。
   * monitorPanel.ts の show() 冒頭コメント参照)ため、webview からの "ready" を受けてから送る。 */
  private pendingOpenDeviceId: string | undefined;
  /** runStarted〜runEnded の間だけ true(自動オープン中)。この間の scenarioStarted で実行中シナリオの
   * platform を live.preferPlatform へ渡し、選択中デバイスがミスマッチなら選び直させる。 */
  private runAutoOpenActive = false;

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    cli: FtesterCli,
    testTree: FtesterTestTree,
    eventBus: RunEventBus,
  ) {
    this.deps = {
      workspaceRoot: this.workspaceRoot,
      getConfig: this.getConfig,
      outputChannel: this.outputChannel,
      post: (message) => {
        void this.panel?.webview.postMessage(message);
      },
      isPanelActive: () => this.panel !== undefined,
      // デバイスモニターの設定タブ「ポーリングモードを使用する」と workspaceState を共有する
      // (monitorPanel.ts と同じキー。トグル直後の即時反映はしない: 次のデバイス選択/表示状態変化で
      // 追いつく。優先実装は device 選択変更時の再評価のみで足りるため)。
      isPollingMode: () => this.context.workspaceState.get<boolean>("monitor.pollingMode", false),
      openGeneratedDocument: (filePath) => this.openGeneratedDocument(filePath),
    };
    this.live = new MonitorLiveController(this.deps, cli, () => void testTree.refresh());
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
  }

  private handleBusMessage(message: RunBusMessage): void {
    if (!this.getConfig().liveControlOnRun) {
      return;
    }
    switch (message.type) {
      case "runStarted":
        if (!message.isDryRun) {
          this.runAutoOpenActive = true;
          this.show(true);
        }
        break;
      case "event":
        // 実行中シナリオの platform を拾い、選択中デバイスがミスマッチなら一覧先頭から選び直させる
        // (worker id 形式は "platform:name"。model.ts の WorkerInfo.id / ApiWorkersReadyEvent と同期)。
        if (this.runAutoOpenActive && message.event.kind === "scenarioStarted") {
          const platform = this.runScenarioPlatform(message.event.worker);
          if (platform) {
            this.live.preferPlatform(platform);
          }
        }
        break;
      case "runEnded":
        this.runAutoOpenActive = false;
        break;
    }
  }

  /** scenarioStarted の worker(並列=プロファイル実行時のみ付与)から platform を取り出す。worker が
   * 無い単機実行(prepareForRun が事前にデバイスを確定済み)では反応的な切替をしない: ここで
   * config.platform(既定 "ios")へ倒すと、Android の単機実行の完了時に iOS デバイスへ誤って
   * 切り替わる不具合になる(実測)。 */
  private runScenarioPlatform(worker: string | undefined): "ios" | "android" | undefined {
    if (!worker) {
      return undefined;
    }
    const platform = worker.split(":")[0];
    return platform === "ios" || platform === "android" ? platform : undefined;
  }

  /** モニター(monitorPanel.ts)の openGeneratedDocument と同方針: 生成ソースをパネルの隣の列に開き
   * ライブ操作パネルの表示を覆わないようにする。 */
  private openGeneratedDocument(filePath: string): void {
    const liveColumn = this.panel?.viewColumn ?? vscode.ViewColumn.Two;
    const target: vscode.ViewColumn = liveColumn > vscode.ViewColumn.One ? liveColumn - 1 : liveColumn + 1;
    void vscode.window.showTextDocument(vscode.Uri.file(filePath), { viewColumn: target });
  }

  private handleWebviewMessage(message: unknown): void {
    if (isLiveWebviewEnvelope(message)) {
      this.live.handleWebviewMessage(message.message);
      return;
    }
    if (!isRecord(message) || typeof message.type !== "string") {
      return;
    }
    switch (message.type) {
      case "ready":
        if (this.pendingOpenDeviceId !== undefined) {
          const id = this.pendingOpenDeviceId;
          this.pendingOpenDeviceId = undefined;
          void this.panel?.webview.postMessage({ type: "openDevice", id });
        }
        break;
      case "streamStall":
        if (message.scope === "live") {
          this.outputChannel.appendLine(
            "[live-stream] キーフレーム未受信のままのためヘルパーを再起動します。",
          );
          this.live.restartStream();
        }
        break;
      case "codecError":
        if (message.scope === "live") {
          this.outputChannel.appendLine(
            "[live-stream] WebCodecs 未対応/デコード失敗のため mjpeg へフォールバックします。",
          );
          this.live.fallbackToMjpeg();
        }
        break;
      default:
        break;
    }
  }

  /** forceRefresh: 既に開いているパネルへ選択中デバイスの再バインドを促す(新規作成時は webview の
   * initLive() が refreshDevices を送るため不要)。ftester.showLiveControl(手動)と runStarted
   * (自動、既存パネル時)の両方から使う。 */
  /** ライブパネルを開く列(=可視エディタの右隣)。ViewColumn.Beside はアクティブ列基準の相対指定で、
   * 生成時に activeTextEditor が undefined(webview フォーカス中など)だとエディタ列へ被って
   * エディタを覆う不具合が出る(実測・間欠)。activeTextEditor→可視エディタ先頭→One の順で基準列を
   * 決め、その +1 を明示的に返すことで相対指定を避ける。 */
  private resolveTargetColumn(): vscode.ViewColumn {
    const base =
      vscode.window.activeTextEditor?.viewColumn ??
      vscode.window.visibleTextEditors[0]?.viewColumn ??
      vscode.ViewColumn.One;
    return (base + 1) as vscode.ViewColumn;
  }

  show(forceRefresh = false): void {
    if (this.panel) {
      // 通常は今の列のまま前面へ(第1引数 undefined=列を動かさない・preserveFocus でエディタの
      // フォーカスと表示を保つ)。ただしエディタと同じ列に同居してしまっている場合だけ、右隣の列へ
      // 移してエディタを覆わないようにする(過去の生成不具合やユーザーのタブ移動からの自己修復)。
      const panelColumn = this.panel.viewColumn;
      const sharesWithEditor =
        panelColumn !== undefined &&
        vscode.window.visibleTextEditors.some((editor) => editor.viewColumn === panelColumn);
      this.panel.reveal(sharesWithEditor ? this.resolveTargetColumn() : undefined, true);
      if (forceRefresh) {
        void this.panel.webview.postMessage({ type: "refreshDevicesFromHost" });
      }
      return;
    }
    // エディタの右隣の列に開く(resolveTargetColumn は Beside 相対を避け列番号を明示)。
    // preserveFocus=true でエディタの表示・フォーカスを保つ(ライブ画面は「見る」用途で、開いた瞬間に
    // エディタを隠さない)。
    const panel = vscode.window.createWebviewPanel(
      VIEW_TYPE,
      LIVE_PANEL_TITLE,
      { viewColumn: this.resolveTargetColumn(), preserveFocus: true },
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(this.context.extensionUri, "media")],
      },
    );
    this.panel = panel;
    panel.webview.html = renderLiveHtml(panel.webview, this.context.extensionUri);
    panel.webview.onDidReceiveMessage((message: unknown) => this.handleWebviewMessage(message));
    panel.onDidChangeViewState((event) => {
      void panel.webview.postMessage({ type: "panelVisible", visible: event.webviewPanel.visible });
    });
    panel.onDidDispose(() => {
      this.live.stopProcesses();
      this.panel = undefined;
    });
  }

  /** Run Test 実行前(runHandler.ts)から呼ばれる。機能 OFF なら即 undefined(呼び出し元が既存の
   * フォールバックへ進む)。パネルを開くだけで表示状態の強制更新はしない(デバイス選択・ストリーミング
   * 起動の強制は MonitorLiveController.prepareForRun が担う)。 */
  async prepareForRun(platform: "ios" | "android"): Promise<LiveRunTarget | undefined> {
    if (!this.getConfig().liveControlOnRun) {
      return undefined;
    }
    this.show(false);
    return await this.live.prepareForRun(platform, 8000);
  }

  /** デバイスタイル右クリック「ライブ操作」(monitorPanel.ts の openLiveForDevice)。 */
  openForDevice(id: string): void {
    const alreadyOpen = this.panel !== undefined;
    this.show();
    if (alreadyOpen) {
      void this.panel?.webview.postMessage({ type: "openDevice", id });
    } else {
      this.pendingOpenDeviceId = id;
    }
  }

  dispose(): void {
    this.unsubscribeBus();
    this.live.dispose();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }
}

export function registerLivePanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
  cli: FtesterCli,
  testTree: FtesterTestTree,
  eventBus: RunEventBus,
): {
  openForDevice(id: string): void;
  prepareForRun(platform: "ios" | "android"): Promise<LiveRunTarget | undefined>;
} {
  const controller = new LivePanelController(
    context,
    workspaceRoot,
    getConfig,
    outputChannel,
    cli,
    testTree,
    eventBus,
  );

  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  statusItem.text = "$(device-mobile) ライブ操作";
  statusItem.tooltip = "ftester: ライブ操作を表示";
  statusItem.command = "ftester.showLiveControl";
  statusItem.show();

  context.subscriptions.push(
    controller,
    statusItem,
    vscode.commands.registerCommand("ftester.showLiveControl", () => controller.show(true)),
  );

  return {
    openForDevice: (id) => controller.openForDevice(id),
    prepareForRun: (platform) => controller.prepareForRun(platform),
  };
}
