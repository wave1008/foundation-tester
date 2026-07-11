// livePanel.ts
// ライブ操作パネルの WebviewPanel(コマンド `ftester.showLiveControl`)。
// macOS GUI 版(Sources/ftester-gui/LiveView.swift + AppModel.swift の refreshLive/liveAction)の
// VSCode 版: スクリーンショットをクリック/要素一覧クリックでタップ、スワイプ、テキスト入力、
// アプリの起動/終了/インストールを行う。
//
// - `ftester api list-devices` はワンショット(即座に1行JSONを出して終了する)コマンドで、
//   cli.ts の FtesterCli(直列実行キュー)には乗せない。FtesterCli のキューは `ftester api run`
//   (シナリオ実行。内部で `swift build` を伴い得るため同時に2プロセス走らせない SPM ビルドロック
//   対策)と共有されており、実行が長時間(数分)続いている間はキューに積んだ要求が実行終了まで
//   ブロックされる。ライブ操作パネルは「今の画面を見ながらすぐ触る」ためのものなので、実行中でも
//   待たされずに応答する必要がある。そのため monitorPanel.ts の devicesUp/devicesDown と同じ方針で、
//   専用に spawn する(runOneShot。SPM ビルドロックへの影響は無い: list-devices はビルドを一切
//   行わないドライバ直叩きの操作なので、run 側の swift build と競合しない)。
// - タップ/入力/スワイプ/起動/終了/インストール/スナップショット取得(Phase 4 高速化、旧実装は
//   これらも `ftester api live <sub>` を毎回ワンショット spawn し、操作後に固定700ms待ってから
//   別プロセスで snapshot を取り直していた=1操作あたりプロセス起動2回+700ms)は、選択デバイスごとに
//   `ftester api live serve` を常駐 spawn し(startServeProcess/stopServeProcess)、stdin へ
//   NDJSON でコマンドを送って stdout の NDJSON イベント(NdjsonParser で受ける)を待つ方式に
//   置き換えた。プロセス管理は monitorPanel.ts の host-metrics プロセス管理パターン
//   (startHostMetricsProcess/stopHostMetricsProcess。v0.0.65)をそのまま踏襲する: stdin パイプ保持
//   (EOF が終了指示)・SIGTERM 送信後2秒で SIGKILL・予期しない終了は5秒後に自動再起動・起動10秒未満の
//   異常終了が3連続したら諦める(serveGaveUp)。ただし host-metrics と違い serve はデバイスごとの
//   状態を持つプロセスなので、デバイス選択が変わったら明示的に再バインド(停止→新デバイスで起動)し、
//   その際は諦め状態もリセットする(=「デバイスを選び直す」操作そのものが host-metrics の
//   「パネル開き直し/再起動ボタン」に相当する回復経路になる。この設計だと専用の再起動ボタンは不要)。
//   操作後の追加待ちは行わない(Phase 2でブリッジの操作応答=UI整定済みになったため)。
// - パネルはシングルトン(monitorPanel.ts / healReviewPanel.ts と同じ)。
// - 座標変換(クリック→ポイント座標、frame→表示px)・レスポンス検証・CLI引数組み立て・NDJSON
//   コマンド組み立て/イベント検証は liveModel.ts(vscode 非依存)に切り出してある。webview 側
//   (CSP により liveModel.ts を import できない)では、ホバー枠オーバーレイ用に
//   frameToDisplayRect と同じ計算だけを手書きで複製している(healReviewPanel.ts の healModel.ts
//   複製と同じ方針)。要素一覧の表示テキストは host 側で liveModel.formatElementLine
//   (toSnapshotMessage 経由)を使って事前整形して送るため、webview 側での複製は不要。

import { randomBytes } from "node:crypto";
import { type ChildProcessByStdio, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Readable, Writable } from "node:stream";
import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import {
  buildDeviceArgs,
  devicesToOptions,
  fallbackDeviceOption,
  isLiveFromWebviewMessage,
  type LiveActionResult,
  type LiveDeviceOption,
  type LiveDeviceRef,
  type LiveErrorResult,
  type LivePlatform,
  type LiveServeCommand,
  type LiveSize,
  type LiveSnapshot,
  type LiveToWebviewMessage,
  parseListDevicesResult,
  parseLiveServeEvent,
  pointFromClick,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  toSnapshotMessage,
} from "./liveModel";
import { NdjsonParser } from "./ndjson";

const VIEW_TYPE = "ftesterLiveControl";
const PANEL_TITLE = "ftester ライブ操作";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts/monitorPanel.ts と同じ形。
 * list-devices のワンショット spawn 専用)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/**
 * serve プロセス用: stdin もパイプで保持する(monitorPanel.ts の MonitorProcess/host-metrics
 * プロセスと同じ形。`ftester api live serve` は stdin へのコマンド送信と EOF 終了指示の両方に
 * stdin パイプを使うため、stdio を "ignore" にはできない)。
 */
type ServeProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** serve への1リクエスト(コマンド送信〜応答受信)のタイムアウト(ms)。通常は1秒未満で応答が
 * 返るが、アプリ起動(ブリッジ側の静止待ち上限10秒)等を考慮して余裕を持たせた安全弁。
 * 応答が無いまま常駐プロセスが停止したり壊れたりしても busy 状態のまま固まらないようにする。 */
const SERVE_REQUEST_TIMEOUT_MS = 20000;

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

/** sendServeCommand() が返す1リクエスト分の結果。action は refresh(アクション無し)のときのみ
 * undefined になる(snapshot は refresh でも常に届く)。 */
interface ServeRequestOutcome {
  readonly action: LiveActionResult | undefined;
  readonly snapshot: LiveSnapshot | LiveErrorResult;
}

/** 送信中(応答待ち)の serve リクエスト1件分。同時に2件以上送らない(busy フラグで直列化)ため
 * キューではなく単一スロットで管理する(activeChild と同じ「一度に1つだけ」の設計)。 */
interface PendingServeRequest {
  /** refresh は actionResult を出さないため false。 */
  readonly expectsAction: boolean;
  /** actionResult イベントが先に届いたら保持し、snapshot イベント到着時にまとめて resolve する。 */
  action: LiveActionResult | undefined;
  readonly resolve: (outcome: ServeRequestOutcome) => void;
  readonly timeout: ReturnType<typeof setTimeout>;
}

class LiveController implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private devices: LiveDeviceOption[] = [];
  private selectedDeviceId: string | undefined;
  /** 直近の snapshot の screen(ポイント座標のサイズ)。クリック→タップ座標変換に使う。 */
  private lastScreen: LiveSize | undefined;
  private busy = false;
  /** list-devices のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;

  // ---- live serve(常駐プロセス。デバイス選択ごとに1つ)。ファイル冒頭のコメント参照 ----
  private serveProcess: ServeProcess | undefined;
  /** serveProcess が実際にバインドされている(起動時に渡した)デバイス。selectServeProcess の
   * 「デバイスが変わったか」判定、および再起動時に同じデバイスへ再バインドするために保持する。 */
  private serveDevice: LiveDeviceRef | undefined;
  /** stopServeProcess() 経由(dispose/再バインド)による意図した終了かどうか
   * (monitorPanel.ts の stoppingHostMetrics と同じ役割)。 */
  private stoppingServe = false;
  /** rebindServeProcess() の多重起動ガード(monitorPanel.ts の hostMetricsRestartPending と同じ役割)。
   * true の間に来た再バインド要求は serveDevice の更新だけ行い、進行中の切り替えが完了した時点の
   * 最新の serveDevice を使って起動する(restartMonitorProcess と同じ「最終的に最新設定が勝つ」方式)。 */
  private serveRestartPending = false;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/停止時に必ずクリアする。 */
  private serveRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private serveStartedAt: number | undefined;
  /** 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める。 */
  private serveFailureStreak = 0;
  /** 自動再起動を諦めた状態かどうか。true の間は close イベントで再起動をスケジュールしない。
   * デバイスを選び直す(rebindServeProcess が走る)と giveUp を無視して仕切り直すため、専用の
   * 「再起動」ボタンは不要(ファイル冒頭のコメント参照)。 */
  private serveGaveUp = false;
  /** 送信中(応答待ち)の serve リクエスト。同時に1件のみ(busy フラグで直列化されるため)。 */
  private pendingServeRequest: PendingServeRequest | undefined;

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
      this.stopServeProcess();
    });

    void this.refreshDevices();
  }

  dispose(): void {
    this.killActiveChild();
    this.stopServeProcess();
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
    this.ensureServeProcessForSelection();
  }

  private applyFallback(config: FtesterConfig, bannerMessage: string): void {
    const option = fallbackDeviceOption({ platform: config.platform, port: config.port, serial: config.serial });
    this.applyDevices([option], bannerMessage);
  }

  // ---- live serve(常駐プロセス)の起動・停止・再バインド ------------------------------------
  // ファイル冒頭のコメント参照(monitorPanel.ts の host-metrics プロセス管理パターンを踏襲)。

  /** 現在選択中のデバイスに serve プロセスをバインドする(未選択なら止める)。デバイス一覧の
   * 取得・切り替えのたびに呼ぶ(applyDevices 経由)。 */
  private ensureServeProcessForSelection(): void {
    const device = this.currentDeviceRef();
    if (!device) {
      this.serveDevice = undefined;
      this.stopServeProcess();
      return;
    }
    this.ensureServeProcess(device);
  }

  /** device 向けの serve プロセスが既に起動していれば何もしない。そうでなければ
   * (未選択→選択・別デバイスへの切り替え・予期しない終了[giveUp 含む]のいずれでも)再バインドする。 */
  private ensureServeProcess(device: LiveDeviceRef): void {
    if (this.serveProcess && this.serveDevice && sameLiveDeviceRef(this.serveDevice, device)) {
      return;
    }
    this.rebindServeProcess(device);
  }

  /**
   * 現在の serve プロセス(あれば)を止めてから device 向けに起動し直す。デバイス選択操作
   * (selectDevice/デバイス一覧の再取得)起点の明示的な再バインドなので、直前の giveUp 状態は
   * 無視して仕切り直す(giveUp が抑止するのは scheduleServeRestart() の無人5秒後リトライだけ)。
   * 多重起動ガードは restartMonitorProcess/restartHostMetricsProcess と同じ理由
   * (デバイスの連続切り替えで stop/start が重なるのを防ぐ。ガード中の呼び出しは serveDevice の
   * 更新だけ行い、進行中の切り替え完了後は常に最新の serveDevice へ起動する)。
   */
  private rebindServeProcess(device: LiveDeviceRef): void {
    this.serveFailureStreak = 0;
    this.serveGaveUp = false;
    this.serveDevice = device;
    if (this.serveRestartPending) {
      return;
    }
    this.serveRestartPending = true;
    const proc = this.serveProcess;
    // 停止処理(SIGTERM→close)が終わるまでの間、旧プロセスへの参照を残さない。sendServeCommand は
    // serveProcess が未設定の間「常駐プロセスが起動していません」を返すので、切り替え中に
    // (busy ガードをすり抜けて)コマンドが送られても、停止処理中の旧プロセス[=旧デバイス宛]に
    // 誤って届くことは無い。
    this.serveProcess = undefined;
    this.killServeProcess(proc);
    const startLatest = (): void => {
      this.serveRestartPending = false;
      const target = this.serveDevice;
      if (target) {
        this.startServeProcess(target);
      }
    };
    if (!proc) {
      startLatest();
      return;
    }
    proc.once("close", startLatest);
  }

  /** `ftester api live serve` を device 向けに spawn する。stdin はパイプで保持したまま何も
   * 書かない箇所を除き、コマンド送信にも使う(EOF が終了指示なのは monitor/host-metrics と同じ)。 */
  private startServeProcess(device: LiveDeviceRef): void {
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const config = this.getConfig();
    let proc: ServeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "live", "serve", ...buildDeviceArgs(device)], {
        cwd: this.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.outputChannel.appendLine(`[live serve] プロセスの起動に失敗しました: ${String(error)}`);
      return;
    }
    proc.stdin.on("error", () => undefined);

    this.stoppingServe = false;
    this.serveProcess = proc;
    this.serveStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => this.handleServeEvent(value),
      (line) => this.outputChannel.appendLine(`[live serve stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.outputChannel.appendLine(`[live serve stderr] ${JSON.stringify(value)}`),
      (line) => this.outputChannel.appendLine(`[live serve stderr] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.outputChannel.appendLine(`[live serve] プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.serveProcess === proc) {
        this.serveProcess = undefined;
      }
      this.failPendingServeRequest("ライブ操作の常駐プロセスが終了しました。");
      // 意図した停止(dispose/再バインド)かどうかはフラグだけで判定する(monitorPanel.ts と同じ理由)。
      const selfInitiated = this.stoppingServe;
      this.stoppingServe = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleServeRestart();
    });
  }

  /**
   * serve プロセスの予期しない終了を受けて、5秒後に再起動するか諦めるかを決める
   * (monitorPanel.ts の scheduleHostMetricsRestart と同じロジック)。起動後10秒未満での異常終了が
   * 3回連続したら諦める(旧バイナリに `api live serve` が無い環境等で無限に再起動ループしないための
   * 安全弁)。10秒以上動いてからの終了は正常運転とみなして連続回数をリセットする。
   */
  private scheduleServeRestart(): void {
    const elapsedMs = Date.now() - (this.serveStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.serveFailureStreak += 1;
    } else {
      this.serveFailureStreak = 0;
    }
    if (this.serveFailureStreak >= 3) {
      if (!this.serveGaveUp) {
        this.serveGaveUp = true;
        this.outputChannel.appendLine(
          "[live serve] 起動直後の異常終了が続いたため自動再起動を停止しました。" +
            "デバイスを選び直すか、パネルを開き直すと再試行します。",
        );
      }
      return;
    }
    this.serveRestartTimer = setTimeout(() => {
      this.serveRestartTimer = undefined;
      if (this.panel && this.serveDevice) {
        this.startServeProcess(this.serveDevice);
      }
    }, 5000);
  }

  /** 実行中の serve プロセスがあれば止めて(this.serveProcess も即座に未設定に戻す)、参照を
   * 手放す(dispose/panel破棄から呼ぶ。デバイス切り替え中の再バインドは rebindServeProcess が
   * 個別に this.serveProcess を扱うため、こちらは呼ばない)。 */
  private stopServeProcess(): void {
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const proc = this.serveProcess;
    this.serveProcess = undefined;
    this.killServeProcess(proc);
  }

  /** proc(あれば)を SIGTERM(2秒後 SIGKILL)で止める(stdin EOF も送ってどちらでもクリーンに
   * 終了できるようにする)。this.serveProcess の書き換えは行わない(呼び出し元の責務。
   * rebindServeProcess/stopServeProcess のどちらも、旧プロセスへの参照を手放してから呼ぶ)。 */
  private killServeProcess(proc: ServeProcess | undefined): void {
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingServe = true;
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** serve の stdout から届いた NDJSON 1行を pendingServeRequest に配る。actionResult は
   * 保持だけして、続く snapshot イベントで両方まとめて resolve する(ファイル冒頭プロトコル参照)。 */
  private handleServeEvent(value: unknown): void {
    const event = parseLiveServeEvent(value);
    if (!event) {
      this.outputChannel.appendLine(`[live serve] 未知の形式の行を無視しました: ${JSON.stringify(value)}`);
      return;
    }
    const pending = this.pendingServeRequest;
    if (!pending) {
      this.outputChannel.appendLine(`[live serve] 対応するリクエストが無いイベントを受信しました(${event.kind})`);
      return;
    }
    if (event.kind === "actionResult") {
      pending.action = event.result;
      return;
    }
    this.settlePendingServeRequest({ action: pending.action, snapshot: event.result });
  }

  private settlePendingServeRequest(outcome: ServeRequestOutcome): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    this.pendingServeRequest = undefined;
    clearTimeout(pending.timeout);
    pending.resolve(outcome);
  }

  /** 応答を受け取れなくなった(プロセス終了・タイムアウト)ときに、待たせている呼び出し元を
   * エラー結果で解放する(busy 状態のまま固まらないようにする安全弁)。 */
  private failPendingServeRequest(message: string): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    this.settlePendingServeRequest({
      action: pending.expectsAction ? { ok: false, error: message } : undefined,
      snapshot: { ok: false, error: message },
    });
  }

  /** command を serve の stdin へ送り、対応する応答(actionResult[refresh以外]+snapshot)が
   * 揃うまで待つ。serve が起動していなければ CLI を呼ばずに即座にエラー結果を返す。 */
  private sendServeCommand(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    const proc = this.serveProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      const message = "ライブ操作の常駐プロセスが起動していません。デバイスを選び直してください。";
      return Promise.resolve({
        action: command.cmd === "refresh" ? undefined : { ok: false, error: message },
        snapshot: { ok: false, error: message },
      });
    }
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        this.failPendingServeRequest("ライブ操作の応答がタイムアウトしました(常駐プロセスが応答していません)。");
      }, SERVE_REQUEST_TIMEOUT_MS);
      this.pendingServeRequest = { expectsAction: command.cmd !== "refresh", action: undefined, resolve, timeout };
      proc.stdin.write(serializeLiveServeCommand(command));
    });
  }

  // ---- snapshot -------------------------------------------------------------------

  private applySnapshotResult(result: LiveSnapshot | LiveErrorResult): void {
    if (!result.ok) {
      this.post({ type: "actionError", message: result.error });
      return;
    }
    this.lastScreen = result.screen;
    this.post(toSnapshotMessage(result));
  }

  private async fetchSnapshot(): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.post({ type: "actionError", message: "デバイスが選択されていません。" });
      return;
    }
    this.ensureServeProcess(device);
    const { snapshot } = await this.sendServeCommand({ cmd: "refresh" });
    this.applySnapshotResult(snapshot);
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

  /** serve へ1コマンド送って結果を反映する。成功時は serve が続けて返す観測イベント(操作後の
   * 追加待ちなしで届く。ブリッジ応答=UI整定済みのため)をそのまま画面へ反映する。失敗時は
   * 旧ワンショット版と同じく画面を再取得しない(観測イベント自体は届くが反映せず、直近のエラーを
   * 表示する)。 */
  private async runAction(command: LiveServeCommand): Promise<void> {
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
      this.ensureServeProcess(device);
      const { action, snapshot } = await this.sendServeCommand(command);
      if (action && !action.ok) {
        this.post({ type: "actionError", message: action.error });
        return;
      }
      this.applySnapshotResult(snapshot);
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
          this.ensureServeProcessForSelection();
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
        void this.runAction({ cmd: "tap", x: point.x, y: point.y });
        break;
      }
      case "tapRef":
        void this.runAction({ cmd: "tap", ref: message.ref });
        break;
      case "swipe":
        void this.runAction({ cmd: "swipe", direction: message.direction });
        break;
      case "typeText": {
        if (message.text.trim().length === 0) {
          this.post({ type: "actionError", message: "入力するテキストを入力してください。" });
          break;
        }
        void this.runAction({ cmd: "type", text: message.text, ref: message.ref });
        break;
      }
      case "launch": {
        const bundleId = message.bundleId.trim();
        if (bundleId.length === 0) {
          this.post({ type: "actionError", message: "bundle ID / パッケージ名を入力してください。" });
          break;
        }
        void this.runAction({ cmd: "launch", bundle: bundleId });
        break;
      }
      case "terminate":
        void this.runAction({ cmd: "terminate" });
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
        void this.runAction({ cmd: "install", path: expanded });
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
  /* ホバー色はテーマ値そのままだと濃い(2026-07-11 ユーザー指摘)ため、モニターパネルの
     行ホバー(.machine-device-row/.device-pick-row)と同じ式で50%透過に薄める。 */
  .element-row:hover { background-color: color-mix(in srgb, var(--vscode-list-hoverBackground) 50%, transparent); }
  /* 選択色は拡張内で統一(2026-07-11 ユーザー指示): モニターパネルのプロファイルタブの
     ヘッダーバー・デバイス行選択・デバイス選択モーダルのチェック行と同じ
     editorGroupHeader-tabsBackground。薄い背景のため前景色の上書きは不要。 */
  .element-row.selected {
    background-color: var(--vscode-editorGroupHeader-tabsBackground, rgba(128, 128, 128, 0.15));
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
