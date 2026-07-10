// livePanel.ts
// ライブ操作パネルの WebviewPanel(コマンド `ftester.showLiveControl`)。
// macOS GUI 版(Sources/ftester-gui/LiveView.swift + AppModel.swift の refreshLive/liveAction)の
// VSCode 版: スクリーンショットをクリック/要素一覧クリックでタップ、スワイプ、テキスト入力、
// アプリの起動/終了/インストールを行う。
//
// - `ftester api list-devices` / `ftester api live <sub>` はいずれもワンショット(即座に1行JSONを
//   出して終了する)コマンドだが、cli.ts の FtesterCli(直列実行キュー)には乗せない。
//   FtesterCli のキューは `ftester api run`(シナリオ実行。内部で `swift build` を伴い得るため
//   同時に2プロセス走らせない SPM ビルドロック対策)と共有されており、実行が長時間(数分)
//   続いている間はキューに積んだ要求が実行終了までブロックされる。ライブ操作パネルは
//   「今の画面を見ながらすぐ触る」ためのものなので、実行中でも待たされずに応答する必要がある。
//   そのため monitorPanel.ts の devicesUp/devicesDown と同じ方針で、専用に spawn する
//   (runOneShot。SPM ビルドロックへの影響は無い: api live/list-devices はビルドを一切行わない
//   ドライバ直叩きの操作なので、run 側の swift build と競合しない)。
// - パネルはシングルトン(monitorPanel.ts / healReviewPanel.ts と同じ)。
// - 座標変換(クリック→ポイント座標、frame→表示px)・レスポンス検証・CLI引数組み立ては
//   liveModel.ts(vscode 非依存)に切り出してある。webview 側(CSP により liveModel.ts を
//   import できない)では、ホバー枠オーバーレイ用に frameToDisplayRect と同じ計算だけを
//   手書きで複製している(healReviewPanel.ts の healModel.ts 複製と同じ方針)。要素一覧の
//   表示テキストは host 側で liveModel.formatElementLine(toSnapshotMessage 経由)を使って
//   事前整形して送るため、webview 側での複製は不要。

import { randomBytes } from "node:crypto";
import { type ChildProcessByStdio, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Readable } from "node:stream";
import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import {
  buildDeviceArgs,
  devicesToOptions,
  fallbackDeviceOption,
  isLiveFromWebviewMessage,
  type LiveDeviceOption,
  type LiveDeviceRef,
  type LivePlatform,
  type LiveSize,
  type LiveToWebviewMessage,
  parseListDevicesResult,
  parseLiveActionResult,
  parseLiveSnapshotResult,
  pointFromClick,
  toSnapshotMessage,
} from "./liveModel";

const VIEW_TYPE = "ftesterLiveControl";
const PANEL_TITLE = "ftester ライブ操作";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts/monitorPanel.ts と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

export function registerLivePanel(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
): void {
  const controller = new LiveController(workspaceRoot, getConfig, outputChannel);
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand("ftester.showLiveControl", () => controller.show()),
  );
}

interface OneShotResult {
  readonly json: unknown;
  readonly exitCode: number | null;
  /** 直近数行の stderr(解析失敗時のエラーメッセージ用)。 */
  readonly stderrTail: string;
}

/**
 * `binaryPath` を FtesterCli のキューに乗せず単発 spawn し、stdout 全体を JSON.parse して返す
 * (契約上どの api live/list-devices コマンドも stdout は1行JSONだけなので、NdjsonParser は使わない)。
 */
function runOneShot(
  binaryPath: string,
  cwd: string,
  args: string[],
  outputChannel: vscode.OutputChannel,
  registerChild: (proc: PipeProcess) => void,
): Promise<OneShotResult> {
  return new Promise((resolve, reject) => {
    let proc: PipeProcess;
    try {
      proc = spawn(binaryPath, args, { cwd, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      reject(new Error(`ftester CLI の起動に失敗しました: ${String(error)}`));
      return;
    }
    registerChild(proc);

    const stdoutChunks: Buffer[] = [];
    const stderrLines: string[] = [];
    proc.stdout.on("data", (chunk: Buffer) => stdoutChunks.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          stderrLines.push(line);
          outputChannel.appendLine(`[live stderr] ${line}`);
        }
      }
    });
    proc.on("error", (error) => {
      reject(new Error(`ftester CLI の実行でエラーが発生しました: ${error.message}`));
    });
    proc.on("close", (exitCode) => {
      const text = Buffer.concat(stdoutChunks).toString("utf8").trim();
      let json: unknown;
      if (text.length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          outputChannel.appendLine(`[ftester] live: stdout を JSON として解析できませんでした: ${text}`);
        }
      }
      resolve({ json, exitCode, stderrTail: stderrLines.slice(-5).join("\n") });
    });
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** "~"/"~/..." だけを展開する(GUI 版 installApp() の expandingTildeInPath と同程度の簡易版)。 */
function expandTilde(rawPath: string): string {
  if (rawPath === "~") {
    return os.homedir();
  }
  if (rawPath.startsWith("~/")) {
    return path.join(os.homedir(), rawPath.slice(2));
  }
  return rawPath;
}

class LiveController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private devices: LiveDeviceOption[] = [];
  private selectedDeviceId: string | undefined;
  /** 直近の snapshot の screen(ポイント座標のサイズ)。クリック→タップ座標変換に使う。 */
  private lastScreen: LiveSize | undefined;
  private busy = false;
  private activeChild: PipeProcess | undefined;

  constructor(
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
  ) {}

  /** コマンド `ftester.showLiveControl` のハンドラ。既に開いていれば reveal するだけ。 */
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
      this.killActiveChild();
    });

    void this.refreshDevices();
  }

  dispose(): void {
    this.killActiveChild();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private post(message: LiveToWebviewMessage): void {
    void this.panel?.webview.postMessage(message);
  }

  private setBusy(busy: boolean): void {
    this.busy = busy;
    this.post({ type: "busy", busy });
  }

  /** 実行中の live CLI プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める(cli.ts と同じ方針)。 */
  private killActiveChild(): void {
    const proc = this.activeChild;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** FtesterCli のキューは使わず専用 spawn する(理由はファイル冒頭のコメント参照)。 */
  private async runCli(args: string[]): Promise<OneShotResult> {
    const config = this.getConfig();
    try {
      return await runOneShot(config.binaryPath, this.workspaceRoot, args, this.outputChannel, (proc) => {
        this.activeChild = proc;
      });
    } finally {
      this.activeChild = undefined;
    }
  }

  private currentDeviceRef(): LiveDeviceRef | undefined {
    const option = this.devices.find((device) => device.id === this.selectedDeviceId);
    return option ? { platform: option.platform, port: option.port, serial: option.serial } : undefined;
  }

  // ---- デバイス一覧 ---------------------------------------------------------------

  private async refreshDevices(): Promise<void> {
    if (this.busy) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(this.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.applyFallback(
        config,
        "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
      );
      return;
    }

    this.setBusy(true);
    try {
      const result = await this.runCli(["api", "list-devices", "--project", resolution.project]);
      const parsed = parseListDevicesResult(result.json);
      if (!parsed) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.applyFallback(
          config,
          `デバイス一覧の取得に失敗しました。マシンプロファイルの設定を確認してください(${detail})`,
        );
        return;
      }
      this.applyDevices(devicesToOptions(parsed.devices), undefined);
    } catch (error) {
      this.applyFallback(config, `デバイス一覧の取得に失敗しました: ${errorMessage(error)}`);
    } finally {
      this.setBusy(false);
    }
  }

  /** 直前の選択が新しい一覧にも存在すれば維持し、無ければ先頭を選択する。 */
  private applyDevices(options: LiveDeviceOption[], bannerMessage: string | undefined): void {
    this.devices = options;
    const stillExists = this.selectedDeviceId !== undefined && options.some((o) => o.id === this.selectedDeviceId);
    this.selectedDeviceId = stillExists ? this.selectedDeviceId : options[0]?.id;
    this.post({ type: "devices", devices: options, selectedId: this.selectedDeviceId });
    this.post({ type: "banner", message: bannerMessage ?? null });
  }

  private applyFallback(config: FtesterConfig, bannerMessage: string): void {
    const option = fallbackDeviceOption({ platform: config.platform, port: config.port, serial: config.serial });
    this.applyDevices([option], bannerMessage);
  }

  // ---- snapshot -------------------------------------------------------------------

  private async fetchSnapshot(): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.post({ type: "actionError", message: "デバイスが選択されていません。" });
      return;
    }
    const result = await this.runCli(["api", "live", "snapshot", ...buildDeviceArgs(device)]);
    const parsed = parseLiveSnapshotResult(result.json);
    if (!parsed) {
      this.post({
        type: "actionError",
        message: `snapshot の応答を解析できませんでした(exit code: ${String(result.exitCode)})。`,
      });
      return;
    }
    if (!parsed.ok) {
      this.post({ type: "actionError", message: parsed.error });
      return;
    }
    this.lastScreen = parsed.screen;
    this.post(toSnapshotMessage(parsed));
  }

  /** 「更新」ボタンのハンドラ。 */
  private async refreshSnapshot(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.setBusy(true);
    try {
      await this.fetchSnapshot();
    } catch (error) {
      this.post({ type: "actionError", message: `snapshot の実行に失敗しました: ${errorMessage(error)}` });
    } finally {
      this.setBusy(false);
    }
  }

  // ---- tap/type/swipe/launch/terminate/install -------------------------------------

  /** `["tap", "--ref", "1"]` のような `api live` サブコマンド以降の引数を受け取り、
   * デバイス引数を付けて実行する。成功時は GUI 版 AppModel.liveAction と同じく
   * 700ms 待って自動で snapshot を再取得する。失敗時は再取得しない(直近のエラーを表示する)。 */
  private async runAction(actionArgs: string[]): Promise<void> {
    if (this.busy) {
      return;
    }
    const device = this.currentDeviceRef();
    if (!device) {
      this.post({ type: "actionError", message: "デバイスが選択されていません。" });
      return;
    }
    this.setBusy(true);
    try {
      const result = await this.runCli(["api", "live", ...actionArgs, ...buildDeviceArgs(device)]);
      const parsed = parseLiveActionResult(result.json);
      if (!parsed) {
        this.post({
          type: "actionError",
          message: `操作の応答を解析できませんでした(exit code: ${String(result.exitCode)})。`,
        });
        return;
      }
      if (!parsed.ok) {
        this.post({ type: "actionError", message: parsed.error });
        return;
      }
      await sleep(700);
      await this.fetchSnapshot();
    } catch (error) {
      this.post({ type: "actionError", message: `操作の実行に失敗しました: ${errorMessage(error)}` });
    } finally {
      this.setBusy(false);
    }
  }

  // ---- webview からのメッセージ -----------------------------------------------------

  private handleWebviewMessage(message: unknown): void {
    if (!isLiveFromWebviewMessage(message)) {
      return;
    }
    switch (message.type) {
      case "refreshDevices":
        void this.refreshDevices();
        break;
      case "selectDevice":
        if (this.devices.some((device) => device.id === message.id)) {
          this.selectedDeviceId = message.id;
        }
        break;
      case "refreshSnapshot":
        void this.refreshSnapshot();
        break;
      case "tapPoint": {
        if (!this.lastScreen) {
          this.post({ type: "actionError", message: "先に「更新」で画面を取得してください。" });
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        void this.runAction(["tap", "--x", String(point.x), "--y", String(point.y)]);
        break;
      }
      case "tapRef":
        void this.runAction(["tap", "--ref", String(message.ref)]);
        break;
      case "swipe":
        void this.runAction(["swipe", "--direction", message.direction]);
        break;
      case "typeText": {
        if (message.text.trim().length === 0) {
          this.post({ type: "actionError", message: "入力するテキストを入力してください。" });
          break;
        }
        const args = ["type", "--text", message.text];
        if (message.ref !== null) {
          args.push("--ref", String(message.ref));
        }
        void this.runAction(args);
        break;
      }
      case "launch": {
        const bundleId = message.bundleId.trim();
        if (bundleId.length === 0) {
          this.post({ type: "actionError", message: "bundle ID / パッケージ名を入力してください。" });
          break;
        }
        void this.runAction(["launch", "--bundle", bundleId]);
        break;
      }
      case "terminate":
        void this.runAction(["terminate"]);
        break;
      case "install": {
        const trimmed = message.path.trim();
        if (trimmed.length === 0) {
          this.post({ type: "actionError", message: "パッケージファイルのパスを入力してください。" });
          break;
        }
        const expanded = expandTilde(trimmed);
        if (!fs.existsSync(expanded)) {
          this.post({ type: "actionError", message: `パッケージファイルが見つかりません: ${trimmed}` });
          break;
        }
        void this.runAction(["install", "--path", expanded]);
        break;
      }
      case "pickInstallFile":
        void this.pickInstallFile(message.platform);
        break;
    }
  }

  private async pickInstallFile(platform: LivePlatform): Promise<void> {
    const isAndroid = platform === "android";
    const uris = await vscode.window.showOpenDialog({
      canSelectMany: false,
      canSelectFiles: true,
      // iOS の .app はディレクトリバンドルなので、ファイルとしてもフォルダとしても選択できるようにする。
      canSelectFolders: !isAndroid,
      openLabel: "選択",
      filters: isAndroid ? { "Android パッケージ": ["apk"] } : { "iOS アプリ": ["app"] },
    });
    const uri = uris?.[0];
    if (!uri) {
      return;
    }
    this.post({ type: "installPathPicked", platform, path: uri.fsPath });
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
  html, body { height: 100%; }
  body {
    margin: 0;
    padding: 0;
    font-family: var(--vscode-font-family, sans-serif);
    font-size: var(--vscode-font-size, 13px);
    color: var(--vscode-foreground);
    background-color: var(--vscode-editor-background);
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
  select, input[type="text"] {
    font-family: inherit;
    font-size: inherit;
    padding: 3px 6px;
    background-color: var(--vscode-input-background);
    color: var(--vscode-input-foreground);
    border: 1px solid var(--vscode-input-border, transparent);
    border-radius: 2px;
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
  #device-warning {
    font-size: 12px;
    color: var(--vscode-editorWarning-foreground, #cca700);
  }
  #busy-label {
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
  .content {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    gap: 12px;
    padding: 12px;
    overflow: hidden;
  }
  .screenshot-pane {
    flex: 1 1 auto;
    min-width: 280px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    overflow: auto;
  }
  .screenshot-wrap {
    position: relative;
    display: inline-block;
    max-width: 100%;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 3px;
    background-color: var(--vscode-input-background, #1e1e1e);
  }
  #screenshot {
    display: none;
    max-width: 100%;
    max-height: calc(100vh - 140px);
    cursor: crosshair;
  }
  #screenshot.visible { display: block; }
  #hover-box {
    position: absolute;
    display: none;
    border: 2px solid var(--vscode-focusBorder, #007acc);
    background-color: rgba(0, 122, 204, 0.15);
    pointer-events: none;
  }
  #screenshot-placeholder {
    padding: 60px 30px;
    text-align: center;
    color: var(--vscode-descriptionForeground);
    font-size: 13px;
    max-width: 320px;
  }
  .hint {
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  .control-pane {
    flex: 0 0 380px;
    min-width: 280px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    overflow-y: auto;
    padding-right: 4px;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .row input[type="text"] { flex: 1 1 auto; min-width: 0; }
  .controls-row .spacer { flex: 1 1 auto; }
  .hint-inline {
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
    white-space: nowrap;
  }
  #action-error {
    display: none;
    font-size: 12px;
    color: var(--vscode-errorForeground, #f14c4c);
    white-space: pre-wrap;
  }
  #action-error.visible { display: block; }
  .elements-header {
    font-size: 12px;
    color: var(--vscode-descriptionForeground);
  }
  #type-ref-hint {
    font-size: 11px;
    color: var(--vscode-descriptionForeground);
  }
  .elements-list {
    flex: 1 1 auto;
    min-height: 80px;
    overflow-y: auto;
    border: 1px solid var(--vscode-widget-border, var(--vscode-panel-border));
    border-radius: 3px;
  }
  .element-row {
    padding: 3px 6px;
    font-family: var(--vscode-editor-font-family, monospace);
    font-size: 11px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    cursor: pointer;
  }
  .element-row:hover { background-color: var(--vscode-list-hoverBackground); }
  .element-row.selected {
    background-color: var(--vscode-list-activeSelectionBackground, #094771);
    color: var(--vscode-list-activeSelectionForeground, #ffffff);
  }
</style>
</head>
<body>
  <div class="toolbar">
    <label for="device-select">デバイス:</label>
    <select id="device-select"></select>
    <button id="btn-refresh-devices" class="secondary">デバイス一覧を更新</button>
    <span id="device-warning"></span>
    <span id="busy-label"></span>
  </div>
  <div id="banner" class="banner"></div>

  <div class="content">
    <div class="screenshot-pane">
      <div class="screenshot-wrap" id="screenshot-wrap">
        <img id="screenshot" alt="スクリーンショット">
        <div id="hover-box"></div>
        <div id="screenshot-placeholder">「更新」ボタンで画面を取得してください</div>
      </div>
      <div class="hint">画像をクリックするとその位置をタップします</div>
    </div>

    <div class="control-pane">
      <div class="row">
        <input id="bundle-id" type="text" placeholder="bundle ID / パッケージ名" value="com.example.sampleapp">
        <button id="btn-launch">起動</button>
        <button id="btn-terminate">終了</button>
      </div>
      <div class="row">
        <input id="ios-path" type="text" placeholder="iOS: .app バンドルのパス">
        <button id="btn-pick-ios" class="secondary">選択...</button>
      </div>
      <div class="row">
        <input id="android-path" type="text" placeholder="Android: .apk のパス">
        <button id="btn-pick-android" class="secondary">選択...</button>
      </div>
      <div class="row">
        <button id="btn-install">インストール</button>
        <span id="install-hint" class="hint-inline"></span>
      </div>

      <div class="row controls-row">
        <button id="btn-refresh-snapshot">更新</button>
        <span class="spacer"></span>
        <button id="btn-swipe-up" class="secondary" title="スワイプ(↑=下へスクロール)">↑</button>
        <button id="btn-swipe-down" class="secondary">↓</button>
        <button id="btn-swipe-left" class="secondary">←</button>
        <button id="btn-swipe-right" class="secondary">→</button>
      </div>

      <div class="row">
        <input id="type-text" type="text" placeholder="入力するテキスト">
        <button id="btn-type">入力</button>
      </div>
      <span id="type-ref-hint">→ フォーカス中の要素に入力</span>

      <div id="action-error"></div>

      <div class="elements-header">要素一覧(クリックでタップ)</div>
      <div id="elements-list" class="elements-list"></div>
    </div>
  </div>

  <script nonce="${nonce}">
  (function () {
    const vscode = acquireVsCodeApi();

    const deviceSelect = document.getElementById('device-select');
    const deviceWarning = document.getElementById('device-warning');
    const busyLabel = document.getElementById('busy-label');
    const banner = document.getElementById('banner');

    const screenshotWrap = document.getElementById('screenshot-wrap');
    const screenshot = document.getElementById('screenshot');
    const hoverBox = document.getElementById('hover-box');
    const screenshotPlaceholder = document.getElementById('screenshot-placeholder');

    const bundleIdInput = document.getElementById('bundle-id');
    const iosPathInput = document.getElementById('ios-path');
    const androidPathInput = document.getElementById('android-path');
    const installHint = document.getElementById('install-hint');
    const typeTextInput = document.getElementById('type-text');
    const typeRefHint = document.getElementById('type-ref-hint');
    const actionError = document.getElementById('action-error');
    const elementsList = document.getElementById('elements-list');

    const STATE_LABEL = {
      connected: '接続済み',
      booted: '起動中',
      offline: '未起動',
      unknown: '状態不明(未確認)',
    };

    let currentDevices = [];
    let lastScreen = null;
    let lastElements = [];
    let selectedRef = null;
    let busy = false;

    const busyButtons = [
      'btn-refresh-devices', 'btn-launch', 'btn-terminate', 'btn-pick-ios', 'btn-pick-android',
      'btn-install', 'btn-refresh-snapshot', 'btn-swipe-up', 'btn-swipe-down', 'btn-swipe-left',
      'btn-swipe-right', 'btn-type',
    ].map((id) => document.getElementById(id));

    function setBusy(value) {
      busy = value;
      for (const b of busyButtons) { b.disabled = value; }
      deviceSelect.disabled = value;
      busyLabel.textContent = value ? '処理中...' : '';
    }

    function showBanner(text) {
      if (!text) { banner.classList.remove('visible'); banner.textContent = ''; return; }
      banner.textContent = text;
      banner.classList.add('visible');
    }

    function showActionError(text) {
      if (!text) { actionError.classList.remove('visible'); actionError.textContent = ''; return; }
      actionError.textContent = text;
      actionError.classList.add('visible');
    }

    // ---- デバイス選択 ---------------------------------------------------------------

    function updateDeviceWarning() {
      const selected = currentDevices.find((d) => d.id === deviceSelect.value);
      deviceWarning.textContent = selected && selected.state !== 'connected' ? '⚠ 接続されていません' : '';
    }

    function updateInstallHint() {
      const selected = currentDevices.find((d) => d.id === deviceSelect.value);
      const isAndroid = !!selected && selected.platform === 'android';
      installHint.textContent = isAndroid ? '→ Android(.apk)のパスを使用' : '→ iOS(.app)のパスを使用';
    }

    function applyDevices(devices, selectedId) {
      currentDevices = devices;
      deviceSelect.innerHTML = '';
      for (const d of devices) {
        const opt = document.createElement('option');
        opt.value = d.id;
        opt.textContent = d.name + '(' + d.platform + ') - ' + (STATE_LABEL[d.state] || d.state);
        deviceSelect.appendChild(opt);
      }
      if (selectedId) { deviceSelect.value = selectedId; }
      updateDeviceWarning();
      updateInstallHint();
    }

    deviceSelect.addEventListener('change', () => {
      updateDeviceWarning();
      updateInstallHint();
      vscode.postMessage({ type: 'selectDevice', id: deviceSelect.value });
    });

    // ---- スクリーンショット(クリック=タップ、要素ホバー=枠オーバーレイ) -----------------

    // liveModel.ts の frameToDisplayRect と同じ計算(webview は CSP により import 不可のため複製)。
    function frameToDisplayRect(frame, screen, display) {
      if (screen.width <= 0 || screen.height <= 0) {
        return { x: 0, y: 0, width: 0, height: 0 };
      }
      const scaleX = display.width / screen.width;
      const scaleY = display.height / screen.height;
      return {
        x: frame.x * scaleX, y: frame.y * scaleY,
        width: frame.width * scaleX, height: frame.height * scaleY,
      };
    }

    function applySnapshot(message) {
      lastScreen = message.screen;
      lastElements = message.elements;
      selectedRef = null;
      typeRefHint.textContent = '→ フォーカス中の要素に入力';
      screenshot.src = 'data:image/jpeg;base64,' + message.image;
      screenshot.classList.add('visible');
      screenshotPlaceholder.style.display = 'none';
      hoverBox.style.display = 'none';
      renderElements();
    }

    screenshot.addEventListener('click', (event) => {
      if (busy || !lastScreen) { return; }
      const rect = screenshot.getBoundingClientRect();
      vscode.postMessage({
        type: 'tapPoint',
        clickX: event.clientX - rect.left,
        clickY: event.clientY - rect.top,
        displayWidth: rect.width,
        displayHeight: rect.height,
      });
    });

    function showHover(element) {
      if (!lastScreen) { return; }
      const rect = screenshot.getBoundingClientRect();
      const box = frameToDisplayRect(element.frame, lastScreen, { width: rect.width, height: rect.height });
      hoverBox.style.left = box.x + 'px';
      hoverBox.style.top = box.y + 'px';
      hoverBox.style.width = box.width + 'px';
      hoverBox.style.height = box.height + 'px';
      hoverBox.style.display = 'block';
    }

    function hideHover() {
      hoverBox.style.display = 'none';
    }

    function renderElements() {
      elementsList.innerHTML = '';
      for (const element of lastElements) {
        const row = document.createElement('div');
        row.className = 'element-row';
        row.textContent = element.line;
        row.addEventListener('click', () => {
          if (busy) { return; }
          for (const r of elementsList.querySelectorAll('.element-row')) { r.classList.remove('selected'); }
          row.classList.add('selected');
          selectedRef = element.ref;
          typeRefHint.textContent = '→ ref ' + element.ref + ' に入力';
          vscode.postMessage({ type: 'tapRef', ref: element.ref });
        });
        row.addEventListener('mouseenter', () => showHover(element));
        row.addEventListener('mouseleave', hideHover);
        elementsList.appendChild(row);
      }
    }

    // ---- 操作ボタン ------------------------------------------------------------------

    document.getElementById('btn-refresh-devices').addEventListener('click', () => {
      vscode.postMessage({ type: 'refreshDevices' });
    });
    document.getElementById('btn-refresh-snapshot').addEventListener('click', () => {
      showActionError('');
      vscode.postMessage({ type: 'refreshSnapshot' });
    });
    document.getElementById('btn-launch').addEventListener('click', () => {
      showActionError('');
      vscode.postMessage({ type: 'launch', bundleId: bundleIdInput.value });
    });
    document.getElementById('btn-terminate').addEventListener('click', () => {
      showActionError('');
      vscode.postMessage({ type: 'terminate' });
    });
    document.getElementById('btn-pick-ios').addEventListener('click', () => {
      vscode.postMessage({ type: 'pickInstallFile', platform: 'ios' });
    });
    document.getElementById('btn-pick-android').addEventListener('click', () => {
      vscode.postMessage({ type: 'pickInstallFile', platform: 'android' });
    });
    document.getElementById('btn-install').addEventListener('click', () => {
      showActionError('');
      const selected = currentDevices.find((d) => d.id === deviceSelect.value);
      const isAndroid = !!selected && selected.platform === 'android';
      const path = isAndroid ? androidPathInput.value : iosPathInput.value;
      vscode.postMessage({ type: 'install', path: path });
    });
    for (const dir of ['up', 'down', 'left', 'right']) {
      document.getElementById('btn-swipe-' + dir).addEventListener('click', () => {
        showActionError('');
        vscode.postMessage({ type: 'swipe', direction: dir });
      });
    }
    document.getElementById('btn-type').addEventListener('click', () => {
      showActionError('');
      vscode.postMessage({ type: 'typeText', text: typeTextInput.value, ref: selectedRef });
    });

    // ---- メッセージ受信 ---------------------------------------------------------------

    window.addEventListener('message', (event) => {
      const message = event.data;
      if (!message || typeof message.type !== 'string') { return; }
      switch (message.type) {
        case 'devices':
          applyDevices(message.devices, message.selectedId);
          break;
        case 'banner':
          showBanner(message.message);
          break;
        case 'snapshot':
          applySnapshot(message);
          break;
        case 'actionError':
          showActionError(message.message);
          break;
        case 'busy':
          setBusy(!!message.busy);
          break;
        case 'installPathPicked':
          if (message.platform === 'android') { androidPathInput.value = message.path; }
          else { iosPathInput.value = message.path; }
          break;
        default:
          break;
      }
    });
  })();
  </script>
</body>
</html>`;
}
