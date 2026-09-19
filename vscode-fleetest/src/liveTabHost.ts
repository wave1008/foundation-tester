// liveTabHost.ts
// デバイスモニター(monitorPanel.ts)の「ライブ操作」タブのロジック本体。MonitorPanelController が
// 他のサブコントローラ(MonitorDeviceStreamController 等)と同じパターンで1つ生成する(自分の
// WebviewPanel は持たない)。実処理は monitorLiveController.ts の MonitorLiveController(LiveDeps
// 経由で疎結合)、HTML/webview 側は monitorHtml.ts の renderLivePanel() /
// src/webview/monitor/liveTab.js(モニターの webview に統合済み)。
//
// 開き方は2経路:
// - 手動: fleetest.showLiveControl コマンド(monitorPanel.ts が自分の登録の中で
//   このコマンドも持つ)。モニターが既に開いていれば選択中デバイスへの再バインドを
//   促す(liveRefreshDevicesFromHost)。
// - 自動: RunEventBus の runStarted(非 dry-run、fleetest.liveControlOnRun 設定が true の間)。
//   デバイスタイル右クリック「ライブ操作」は openForDevice() から呼ばれ、対象デバイスを選択させる。

import type * as vscode from "vscode";
import type { FleetestCli } from "./cli";
import type { FleetestConfig } from "./config";
import type { LiveDeps } from "./liveDeps";
import type { LiveFromWebviewMessage } from "./liveModel";
import type { LiveRunTarget } from "./liveRunTarget";
import { MonitorLiveController } from "./monitorLiveController";
import type { MonitorToWebviewMessage } from "./monitorWebviewMessages";
import type { RunBusMessage, RunEventBus } from "./runEventBus";
import type { FleetestTestTree } from "./testTree";

/** MonitorPanelController からの窓口(MonitorPanelDeps と同じ、必要なものだけを束ねる狭い形)。 */
export interface LiveTabHostDeps {
  post(message: MonitorToWebviewMessage): void;
  /** デバイスモニターの webview パネルが生成済みか(表示中かは問わない)。 */
  isPanelOpen(): boolean;
  /** モニターを開いて(未生成なら作成)「ライブ操作」タブへ切り替える。 */
  showTab(tab: "live"): void;
  /** 設定タブの「ポーリングモードを使用する」現在値(デバイスモニターと共有)。 */
  isPollingMode(): boolean;
  /** 生成したソース(絶対パス)をモニター表示を覆わない列に開く(レコーディング→gen-scenario 完了時)。 */
  openGeneratedDocument(filePath: string): void;
}

/** export はテスト(panelRelocalize.test.mjs)が restartStream 差し替えで relocalize 契約を検証するため。
 * 生成経路は MonitorPanelController のコンストラクタのみ(シングルトン方針は変えない)。 */
export class LiveTabHost implements vscode.Disposable {
  private readonly innerDeps: LiveDeps;
  readonly live: MonitorLiveController;
  private readonly unsubscribeBus: () => void;
  /** openForDevice() がモニター新規作成と同時に呼ばれた場合の openDevice 送信保留先。html 設定直後の
   * postMessage は webview 側 message リスナー登録前に届き握りつぶされる(VS Code既知のレース。
   * monitorPanel.ts の show() 冒頭コメント参照)ため、webview からの "ready" を受けてから送る。 */
  private pendingOpenDeviceId: string | undefined;
  /** runStarted〜runEnded の間だけ true(自動オープン中)。この間の scenarioStarted で実行中シナリオの
   * platform を live.preferPlatform へ渡し、選択中デバイスがミスマッチなら選び直させる。 */
  private runAutoOpenActive = false;

  constructor(
    private readonly deps: LiveTabHostDeps,
    private readonly getConfig: () => FleetestConfig,
    cli: FleetestCli,
    testTree: FleetestTestTree,
    eventBus: RunEventBus,
    workspaceRoot: string,
    outputChannel: vscode.OutputChannel,
  ) {
    this.innerDeps = {
      workspaceRoot,
      getConfig,
      outputChannel,
      post: (message) => this.deps.post(message),
      isPanelActive: () => this.deps.isPanelOpen(),
      isPollingMode: () => this.deps.isPollingMode(),
      openGeneratedDocument: (filePath) => this.deps.openGeneratedDocument(filePath),
    };
    this.live = new MonitorLiveController(this.innerDeps, cli, () => void testTree.refresh());
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
  }

  private handleBusMessage(message: RunBusMessage): void {
    // 操作記録への流し込みは liveControlOnRun とは独立(手動で開いたタブでも流す)。
    // モニター未オープン時は流さない(post は no-op だが無駄を避ける)。
    if (message.type === "event" && message.event.kind === "step" && this.deps.isPanelOpen()) {
      this.live.injectTestStep(message.event);
    }
    if (!this.getConfig().liveControlOnRun) {
      return;
    }
    switch (message.type) {
      case "runStarted":
        // 単一クラス実行のときだけ自動追従する(runHandler.ts が単一デバイスの liveTarget を用意した run
        // = liveFollow=true)。複数クラス(並列バッチ)は liveFollow=false で追従しない。クラス数判定は
        // runHandler に集約し、ここは結果フラグだけを見る(判定の二重化を避ける)。手動オープン時の
        // 操作記録流し込み(上)は liveControlOnRun とも liveFollow とも独立。
        if (!message.isDryRun && message.liveFollow) {
          this.runAutoOpenActive = true;
          this.show();
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

  handleWebviewMessage(message: LiveFromWebviewMessage): void {
    this.live.handleWebviewMessage(message);
  }

  /** webview の "ready" 受信時(monitorPanel.ts の sendInitialState から呼ぶ)。openForDevice() が
   * モニター新規作成と同時に呼ばれていた場合の送信保留分を flush する。 */
  notifyReady(): void {
    if (this.pendingOpenDeviceId !== undefined) {
      const id = this.pendingOpenDeviceId;
      this.pendingOpenDeviceId = undefined;
      this.deps.post({ type: "liveOpenDevice", id });
    }
  }

  /** モニターを「ライブ操作」タブで開き、既に開いていた場合はデバイス一覧を再取得させる
   * (fleetest.showLiveControl・runStarted 自動オープンの両方から使う。新規作成時は webview の
   * initLive() が refreshDevices を送るため不要)。 */
  show(): void {
    const alreadyOpen = this.deps.isPanelOpen();
    this.deps.showTab("live");
    if (alreadyOpen) {
      this.deps.post({ type: "liveRefreshDevicesFromHost" });
    }
  }

  /** デバイスタイル右クリック「ライブ操作」。 */
  openForDevice(id: string): void {
    const alreadyOpen = this.deps.isPanelOpen();
    this.deps.showTab("live");
    if (alreadyOpen) {
      this.deps.post({ type: "liveOpenDevice", id });
    } else {
      this.pendingOpenDeviceId = id;
    }
  }

  /** Run Test 実行前(runHandler.ts)から呼ばれる。機能 OFF なら即 undefined(呼び出し元が既存の
   * フォールバックへ進む)。タブを開くだけで表示状態の強制更新はしない(デバイス選択・ストリーミング
   * 起動の強制は MonitorLiveController.prepareForRun が担う)。 */
  async prepareForRun(platform: "ios" | "android"): Promise<LiveRunTarget | undefined> {
    if (!this.getConfig().liveControlOnRun) {
      return undefined;
    }
    this.deps.showTab("live");
    return await this.live.prepareForRun(platform, 8000);
  }

  /** fleetest.language 変更(monitorPanel.ts の relocalize 経由)。webview.html の再代入は webview を
   * 再読込するが、再読込直後の initLive() が refreshDevices/refreshAppProfiles を能動的に要求するため
   * host 側の再送は不要(liveTab.js 冒頭コメント参照)。稼働中のライブ配信はブラウザ側デコーダごと
   * 失われるため、restartStream() で新キーフレームから再開させる(streamStall と同型)。 */
  restartStream(): void {
    this.live.restartStream();
  }

  /** webview からの codecError(scope:"live")。WebCodecs 未対応/デコード失敗時に mjpeg へ切替える。 */
  fallbackToMjpeg(): void {
    this.live.fallbackToMjpeg();
  }

  /** モニターの webview パネルが破棄された(close/再作成前)ときに呼ぶ。コントローラ自体は
   * MonitorPanelController と同じ寿命で残り続ける(deviceStream.dispose() と同じ規律)。 */
  stopProcesses(): void {
    this.live.stopProcesses();
  }

  dispose(): void {
    this.unsubscribeBus();
    this.live.dispose();
  }
}
