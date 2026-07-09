// monitorPanel.ts
// デバイスモニターの WebviewPanel(コマンド `ftester.showDeviceMonitor`)。
//
// - `ftester api monitor --project <P> --interval <秒> --max-width <px>` を自前で spawn し、
//   NdjsonParser(vscode 非依存)でパース → monitorModel.ts(同じく vscode 非依存)で
//   検証・変換した上で webview.postMessage する。cli.ts の FtesterCli(直列実行キュー)は
//   使わない — monitor は接続中ずっと動き続けるプロセスなので、キューに載せると
//   以後の実行・ステップ取得等の CLI 呼び出しが永久にブロックされてしまうため。
// - パネルはシングルトン(既に開いていれば reveal するだけ)。
// - パネル破棄・拡張 deactivate 時は子プロセスに SIGTERM を送り、2秒後もまだ生きていれば
//   SIGKILL する(cli.ts の cancelCurrent() と同じ方針)。
// - webview からの devicesUp/devicesDown も cli.ts のキューは使わず、ここで直接
//   短命プロセス(`ftester devices up`/`devices down`)を spawn する。多重起動ガードのため
//   実行中は bootBusy:true を webview に送ってボタンを無効化させる。
// - ログレーン表示: RunEventBus(runHandler.ts の実行と同じインスタンスを extension.ts から
//   注入される)を購読し、`ftester api run` の生イベントを runLaneModel.ts(vscode/webview
//   非依存の純粋関数)でレーン用アクションに変換して webview へ転送する。デバイスタイルと
//   ログレーンは device id / worker id が同一規則なので、そのまま突合できる
//   (タイルの「実行中」バッジ・タイル選択によるレーン絞り込み)。

import { randomBytes } from "node:crypto";
import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import {
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  toWebviewMessage,
  type MonitorToWebviewMessage,
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

class MonitorPanelController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private monitorProcess: MonitorProcess | undefined;
  /** stopMonitorProcess() 経由(dispose/再起動)による意図した終了かどうか。 */
  private stoppingMonitor = false;
  private bootBusy = false;

  /** ログレーンの純粋な状態(実行を跨いで保持し、パネル再作成時のハイドレーションに使う)。 */
  private readonly laneState = createRunLaneState();
  /** 一度でも実行が始まった(=レーンセクションを表示すべき)かどうか。 */
  private laneSectionVisible = false;
  private readonly unsubscribeBus: () => void;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
    eventBus: RunEventBus,
  ) {
    this.unsubscribeBus = eventBus.subscribe((message) => this.handleBusMessage(message));
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
    this.hydrateLaneUi();
  }

  dispose(): void {
    this.unsubscribeBus();
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
      case "devicesUp":
        this.runDevicesCommand("up");
        break;
      case "devicesDown":
        this.runDevicesCommand("down");
        break;
      case "restartMonitor":
        this.restartMonitorProcess();
        break;
    }
  }

  private startMonitorProcess(): void {
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
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

  private restartMonitorProcess(): void {
    const proc = this.monitorProcess;
    this.stopMonitorProcess();
    if (!proc) {
      this.startMonitorProcess();
      return;
    }
    proc.once("close", () => this.startMonitorProcess());
  }

  /** `ftester devices up`/`devices down` を短命プロセスとして実行する(多重起動ガード付き)。 */
  private runDevicesCommand(kind: "up" | "down"): void {
    if (this.bootBusy) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    const args: string[] = ["devices", kind];
    if (kind === "up" && resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[ftester] devices ${kind} の起動に失敗しました: ${String(error)}`);
      return;
    }

    this.bootBusy = true;
    this.post({ type: "bootBusy", busy: true });

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

    const finish = (): void => {
      this.bootBusy = false;
      this.post({ type: "bootBusy", busy: false });
    };
    proc.on("error", (error) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} の実行でエラーが発生しました: ${error.message}`,
      );
      finish();
    });
    proc.on("close", (exitCode) => {
      this.outputChannel.appendLine(
        `[ftester] devices ${kind} が終了しました(exit code: ${String(exitCode)})`,
      );
      finish();
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
  button.secondary {
    background-color: var(--vscode-button-secondaryBackground, transparent);
    color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
  }
  button.secondary:hover:not(:disabled) {
    background-color: var(--vscode-button-secondaryHoverBackground, var(--vscode-toolbar-hoverBackground));
  }
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
  }
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
</style>
</head>
<body>
  <div id="toolbar" class="toolbar">
    <button id="btn-devices-up">デバイスを全て起動</button>
    <button id="btn-devices-down" class="secondary">全て終了</button>
    <button id="btn-restart" class="secondary">モニター再起動</button>
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

    const tilePane = document.getElementById('tile-pane');
    const splitter = document.getElementById('splitter');
    const lanesPlaceholder = document.getElementById('lanes-placeholder');
    const lanesGrid = document.getElementById('lanes-grid');
    const lanesSelectionStatus = document.getElementById('lanes-selection-status');
    const lanesRunStatus = document.getElementById('lanes-run-status');

    const STATE_LABEL = {
      connected: '接続済み',
      booted: '起動中(ブリッジ未接続)',
      offline: '未起動',
    };

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
    function availableSplitHeight() {
      const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
      return document.body.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
    }

    // 上下それぞれ最小 MIN_PANE_HEIGHT を確保するようにクランプする。
    function clampTilePaneHeight(height) {
      const available = availableSplitHeight();
      const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
      return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
    }

    function applyTilePaneHeight(height) {
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
      tile.addEventListener('click', () => toggleDeviceSelection(device.id));

      // ヘッダー: 左からプラットフォーム色で装飾したデバイス名、右端に「実行中」
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
        entry.placeholderEl.textContent = entry.device.state === 'offline' ? '未起動' : '未受信';
        entry.frameWrapEl.appendChild(entry.placeholderEl);
      }
    }

    function renderMeta(entry) {
      entry.nameEl.textContent = entry.device.name;
      entry.nameEl.className = 'tile-name tile-name-' + entry.device.platform;
      entry.nameEl.title = entry.device.name + ' (' + entry.device.platform + ')';
      entry.stateBadgeEl.textContent = STATE_LABEL[entry.device.state] || entry.device.state;
      entry.updatedEl.textContent = entry.lastUpdated ? formatTime(entry.lastUpdated) : '';
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
        case 'laneSectionVisible':
          // レーンは常時表示になったため何もしない(TS側からのメッセージ自体は互換のため残る)
          break;
        case 'runEvent':
          applyLaneAction(message.action);
          break;
        case 'laneHydrate':
          applyLaneHydrate(message.snapshot);
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
      for (const entry of tiles.values()) {
        entry.tile.remove();
      }
      tiles.clear();
      selectedDeviceIds.clear();
      emptyMessage.style.display = 'flex';
      vscode.postMessage({ type: 'restartMonitor' });
    });

    updateLaneVisibility();
    updateLanesPlaceholder();
  })();
  </script>
</body>
</html>`;
}
