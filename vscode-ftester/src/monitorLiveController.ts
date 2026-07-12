// monitorLiveController.ts
// デバイスモニターパネル(monitorPanel.ts)の「ライブ操作」タブ担当サブコントローラ。
//
// - `ftester api list-devices` は FtesterCli の直列キュー(`ftester api run` と共有。シナリオ実行が
//   `swift build` を伴い得るため同時2プロセスを防ぐ SPM ビルドロック対策)には乗せず、oneShotCli.ts の
//   runOneShot() で専用 spawn する。ライブ操作は実行中でも待たされず応答する必要があり、
//   list-devices はビルドを伴わないので run 側と競合しないため問題ない。
// - タップ/入力/スワイプ/起動/終了/インストール/スナップショット取得は、選択デバイスごとに
//   `ftester api live serve` を常駐 spawn し、stdin へ NDJSON でコマンドを送って stdout の NDJSON
//   イベント(NdjsonParser)を待つ方式で行う。プロセス管理は monitorProcessManager.ts の host-metrics
//   パターンを踏襲: stdin パイプ保持(EOF が終了指示)・SIGTERM 送信後2秒で SIGKILL・予期しない
//   終了は5秒後に自動再起動・起動10秒未満の異常終了が3連続したら諦める(serveGaveUp)。ただし
//   serve はデバイスごとの状態を持つプロセスなので、デバイス選択が変わったら明示的に再バインド
//   (停止→新デバイスで起動)し諦め状態もリセットする(=デバイスを選び直す操作が host-metrics の
//   「再起動ボタン」に相当する回復経路。専用ボタンは無い)。
// - webview 資産は src/webview/monitor/liveTab.js(main.js から applyLiveMessage を import)。
//   frameToDisplayRect の計算だけを手書きで複製している(要素一覧の表示テキストは host 側で
//   事前整形して送るため複製不要)。liveModel.ts の frameToDisplayRect を変更したら
//   liveTab.js 側も追随させること。

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
  type LiveActionResult,
  type LiveDeviceOption,
  type LiveDeviceRef,
  type LiveErrorResult,
  type LiveFrameResult,
  type LiveFromWebviewMessage,
  type LivePlatform,
  type LiveServeCommand,
  type LiveSize,
  type LiveSnapshot,
  type LiveToWebviewMessage,
  parseListAppsResult,
  parseListDevicesResult,
  parseLiveServeEvent,
  pointFromClick,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  toSnapshotMessage,
} from "./liveModel";
import type { MonitorPanelDeps } from "./monitorPanel";
import { NdjsonParser } from "./ndjson";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";

/**
 * serve プロセス用: stdin もパイプで保持する(monitorProcessManager.ts の MonitorProcess/host-metrics
 * プロセスと同じ形。`ftester api live serve` は stdin へのコマンド送信と EOF 終了指示の両方に
 * stdin パイプを使うため、stdio を "ignore" にはできない)。
 */
type ServeProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** serve への1リクエスト(コマンド送信〜応答受信)のタイムアウト(ms)。通常は1秒未満で応答が
 * 返るが、アプリ起動(ブリッジ側の静止待ち上限10秒)等を考慮して余裕を持たせた安全弁。
 * 応答が無いまま常駐プロセスが停止したり壊れたりしても busy 状態のまま固まらないようにする。 */
const SERVE_REQUEST_TIMEOUT_MS = 20000;

/** 自動フレームを実行できなかった回(busy・パネル非表示・serve 不在)と失敗時の再試行間隔(ms)。
 * 成功時は待ちなしで次フレームを送る(ホットループ防止のため失敗系のみ間隔を空ける)。 */
const FRAME_IDLE_RETRY_MS = 500;

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

/** sendServeCommand/sendServeFrame の resolve に渡す払い出し。resolvesOn で使うフィールドが決まる
 * (snapshot: action?+snapshot、frame: frame のみ)。 */
interface PendingServeOutcome {
  readonly action?: LiveActionResult;
  readonly snapshot?: LiveSnapshot | LiveErrorResult;
  readonly frame?: LiveFrameResult;
}

/** 送信中(応答待ち)の serve リクエスト1件分。自動フレームとユーザー操作が enqueueServeSend で
 * 直列化されるため同時に2件以上送らない(単一スロットで管理。activeChild と同じ「一度に1つだけ」の設計)。 */
interface PendingServeRequest {
  /** refresh/frame は actionResult を出さないため false。 */
  readonly expectsAction: boolean;
  /** どちらの観測イベントで resolve するか。handleServeEvent が届いた kind と照合し、不一致なら
   * 「対応しないイベント」として無視する(自動フレームとユーザー操作の取り違え防止)。 */
  readonly resolvesOn: "snapshot" | "frame";
  /** actionResult イベントが先に届いたら保持し、snapshot イベント到着時にまとめて resolve する。 */
  action: LiveActionResult | undefined;
  readonly resolve: (outcome: PendingServeOutcome) => void;
  readonly timeout: ReturnType<typeof setTimeout>;
}

export class MonitorLiveController implements vscode.Disposable {
  private devices: LiveDeviceOption[] = [];
  private selectedDeviceId: string | undefined;
  /** openDevice 用: 次の applyDevices で優先選択する id(消費したら undefined に戻す)。 */
  private pendingSelectId: string | undefined;
  /** 直近の snapshot の screen(ポイント座標のサイズ)。クリック→タップ座標変換に使う。 */
  private lastScreen: LiveSize | undefined;
  private busy = false;
  /** list-devices のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;
  /** アプリ一覧を取得済みのデバイス id(refreshAppsIfNeeded の再取得判定)。 */
  private lastAppsDeviceId: string | undefined;

  // ---- live serve(常駐プロセス。デバイス選択ごとに1つ)。ファイル冒頭のコメント参照 ----
  private serveProcess: ServeProcess | undefined;
  /** serveProcess が実際にバインドされている(起動時に渡した)デバイス。selectServeProcess の
   * 「デバイスが変わったか」判定、および再起動時に同じデバイスへ再バインドするために保持する。 */
  private serveDevice: LiveDeviceRef | undefined;
  /** stopServeProcess() 経由(dispose/再バインド)による意図した終了かどうか
   * (monitorProcessManager.ts の stoppingHostMetrics と同じ役割)。 */
  private stoppingServe = false;
  /** rebindServeProcess() の多重起動ガード(monitorProcessManager.ts の hostMetricsRestartPending と
   * 同じ役割)。true の間に来た再バインド要求は serveDevice の更新だけ行い、進行中の切り替えが
   * 完了した時点の最新の serveDevice を使って起動する(restartMonitorProcess と同じ
   * 「最終的に最新設定が勝つ」方式)。 */
  private serveRestartPending = false;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/停止時に必ずクリアする。 */
  private serveRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private serveStartedAt: number | undefined;
  /** 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める。 */
  private serveFailureStreak = 0;
  /** 自動再起動を諦めた状態。true の間は close イベントで再起動をスケジュールしない
   * (rebindServeProcess でリセットされる。詳細はファイル冒頭のコメント参照)。 */
  private serveGaveUp = false;
  /** 送信中(応答待ち)の serve リクエスト。同時に1件のみ(enqueueServeSend で直列化されるため)。 */
  private pendingServeRequest: PendingServeRequest | undefined;
  /** serve への送信を直列化するチェーン(自動フレームとユーザー操作の pending 競合を防ぐ)。 */
  private serveSendChain: Promise<unknown> = Promise.resolve();
  /** ライブタブ表示中かどうか(webview からの visibility メッセージで更新)。自動フレームの実行可否
   * (パネル非表示時はスキップ)に使う。 */
  private liveTabVisible = false;
  /** 自動フレームの次回 tick タイマー。 */
  private frameTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(private readonly deps: MonitorPanelDeps) {}

  /** パネル close 時・dispose 時の両方から呼ばれる。パネル再オープン後は webview からの
   * refreshDevices→applyDevices→ensureServeProcessForSelection で serve が再起動される。 */
  stopProcesses(): void {
    this.killActiveChild();
    this.stopServeProcess();
    this.clearFrameTimer();
  }

  dispose(): void {
    this.stopProcesses();
  }

  private post(message: LiveToWebviewMessage): void {
    this.deps.post({ type: "live", message });
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
    const config = this.deps.getConfig();
    try {
      return await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (proc) => {
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
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
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

  // ---- アプリ一覧 -----------------------------------------------------------------

  private async refreshApps(): Promise<void> {
    if (this.busy) {
      return;
    }
    const device = this.currentDeviceRef();
    if (!device) {
      this.post({ type: "appList", apps: [], message: "デバイスが選択されていません。" });
      return;
    }
    const requestedId = this.selectedDeviceId;
    this.setBusy(true);
    try {
      const result = await this.runCli(["api", "list-apps", ...buildDeviceArgs(device)]);
      const apps = parseListAppsResult(result.json);
      if (!apps) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.post({ type: "appList", apps: [], message: `アプリ一覧の取得に失敗しました(${detail})` });
        return;
      }
      this.lastAppsDeviceId = requestedId;
      this.post({ type: "appList", apps, message: null });
    } catch (error) {
      this.post({ type: "appList", apps: [], message: `アプリ一覧の取得に失敗しました: ${errorMessage(error)}` });
    } finally {
      this.setBusy(false);
    }
  }

  /** 選択デバイスのアプリ一覧が未取得のときだけ取得する(デバイス選択の変化に追随する経路)。 */
  private async refreshAppsIfNeeded(): Promise<void> {
    if (this.selectedDeviceId !== undefined && this.lastAppsDeviceId === this.selectedDeviceId) {
      return;
    }
    await this.refreshApps();
  }

  /** pendingSelectId(openDevice 由来)があればそれを優先選択する。無ければ直前の選択が新しい
   * 一覧にも存在するとき維持し、それ以外は先頭を選択する。 */
  private applyDevices(options: LiveDeviceOption[], bannerMessage: string | undefined): void {
    this.devices = options;
    const pending = this.pendingSelectId;
    this.pendingSelectId = undefined;
    const preferred = pending !== undefined && options.some((o) => o.id === pending) ? pending : undefined;
    const stillExists = this.selectedDeviceId !== undefined && options.some((o) => o.id === this.selectedDeviceId);
    this.selectedDeviceId = preferred ?? (stillExists ? this.selectedDeviceId : options[0]?.id);
    this.post({ type: "devices", devices: options, selectedId: this.selectedDeviceId });
    this.post({ type: "banner", message: bannerMessage ?? null });
    this.ensureServeProcessForSelection();
  }

  private applyFallback(config: FtesterConfig, bannerMessage: string): void {
    const option = fallbackDeviceOption({ platform: config.platform, port: config.port, serial: config.serial });
    this.applyDevices([option], bannerMessage);
  }

  /** デバイスタブの右クリック「ライブ操作」から(webview: deviceTiles.js→liveTab.js)。
   * id はモニターと共通の `platform:name`(Swift 側 MonitorTarget.id と devicesToOptions が同形式)。
   * 一覧に無ければ取得し直してから選択し、接続済みなら snapshot まで自動取得する。 */
  private async openDevice(id: string): Promise<void> {
    if (this.busy) {
      // 進行中の refreshDevices があれば、その applyDevices がこの id を優先選択する。
      this.pendingSelectId = id;
      return;
    }
    if (this.devices.some((device) => device.id === id)) {
      this.selectedDeviceId = id;
      this.post({ type: "devices", devices: this.devices, selectedId: id });
      this.ensureServeProcessForSelection();
    } else {
      this.pendingSelectId = id;
      await this.refreshDevices();
    }
    if (this.selectedDeviceId !== id) {
      return; // 一覧取得失敗(フォールバック)や消えたデバイス。banner は refreshDevices 側で表示済み。
    }
    const selected = this.devices.find((device) => device.id === id);
    if (selected?.state === "connected") {
      await this.refreshSnapshot();
    }
    await this.refreshAppsIfNeeded();
  }

  // ---- live serve(常駐プロセス)の起動・停止・再バインド ------------------------------------
  // ファイル冒頭のコメント参照(monitorProcessManager.ts の host-metrics プロセス管理パターンを踏襲)。

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
   * 現在の serve(あれば)を止めて device 向けに起動し直す。明示的な再バインドなので直前の giveUp
   * (抑止対象は scheduleServeRestart の無人5秒後リトライのみ)は無視して仕切り直す。多重起動ガードは
   * デバイス連続切り替えでの stop/start 重複を防ぐ(ガード中は serveDevice 更新のみ行い、進行中の
   * 切り替え完了後は最新の serveDevice へ起動する)。
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
    // 停止処理(SIGTERM→close)完了前に旧プロセスへの参照を消す: sendServeCommand は serveProcess
    // 未設定なら即座にエラーを返すため、切り替え中に送られたコマンドが停止中の旧プロセス
    // (旧デバイス宛)に届くことは無い。
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

  private startServeProcess(device: LiveDeviceRef): void {
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const config = this.deps.getConfig();
    let proc: ServeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "live", "serve", ...buildDeviceArgs(device)], {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[live serve] プロセスの起動に失敗しました: ${String(error)}`);
      return;
    }
    proc.stdin.on("error", () => undefined);

    this.stoppingServe = false;
    this.serveProcess = proc;
    this.serveStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => this.handleServeEvent(value),
      (line) => this.deps.outputChannel.appendLine(`[live serve stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[live serve stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[live serve stderr] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(`[live serve] プロセスでエラーが発生しました: ${error.message}`);
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.serveProcess === proc) {
        this.serveProcess = undefined;
      }
      this.failPendingServeRequest("ライブ操作の常駐プロセスが終了しました。");
      // 意図した停止(dispose/再バインド)かどうかはフラグだけで判定する(monitorProcessManager.ts と同じ理由)。
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
   * (monitorProcessManager.ts の scheduleHostMetricsRestart と同じロジック)。起動後10秒未満での
   * 異常終了が3回連続したら諦める(旧バイナリに `api live serve` が無い環境等で無限に再起動
   * ループしないための安全弁)。10秒以上動いてからの終了は正常運転とみなして連続回数をリセットする。
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
        this.deps.outputChannel.appendLine(
          "[live serve] 起動直後の異常終了が続いたため自動再起動を停止しました。" +
            "デバイスを選び直すか、パネルを開き直すと再試行します。",
        );
      }
      return;
    }
    this.serveRestartTimer = setTimeout(() => {
      this.serveRestartTimer = undefined;
      if (this.deps.isPanelActive() && this.serveDevice) {
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
   * 保持だけして、続く snapshot/frame イベントで resolve する(ファイル冒頭プロトコル参照)。
   * pending.resolvesOn と一致しない kind(自動フレームとユーザー操作の取り違え)は無視する。 */
  private handleServeEvent(value: unknown): void {
    const event = parseLiveServeEvent(value);
    if (!event) {
      this.deps.outputChannel.appendLine(`[live serve] 未知の形式の行を無視しました: ${JSON.stringify(value)}`);
      return;
    }
    const pending = this.pendingServeRequest;
    if (!pending) {
      this.deps.outputChannel.appendLine(
        `[live serve] 対応するリクエストが無いイベントを受信しました(${event.kind})`,
      );
      return;
    }
    if (event.kind === "actionResult") {
      pending.action = event.result;
      return;
    }
    if (event.kind !== pending.resolvesOn) {
      this.deps.outputChannel.appendLine(
        `[live serve] 対応しないイベントを受信しました(期待: ${pending.resolvesOn}、実際: ${event.kind})`,
      );
      return;
    }
    if (event.kind === "snapshot") {
      this.settlePendingServeRequest({ action: pending.action, snapshot: event.result });
    } else {
      this.settlePendingServeRequest({ frame: event.result });
    }
  }

  private settlePendingServeRequest(outcome: PendingServeOutcome): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    this.pendingServeRequest = undefined;
    clearTimeout(pending.timeout);
    pending.resolve(outcome);
  }

  /** 応答を受け取れなくなった(プロセス終了・タイムアウト)ときに、待たせている呼び出し元を
   * エラー結果で解放する(busy 状態のまま固まらないようにする安全弁)。resolvesOn に応じて
   * snapshot/frame のどちらか一方だけを埋める。 */
  private failPendingServeRequest(message: string): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    if (pending.resolvesOn === "frame") {
      this.settlePendingServeRequest({ frame: { ok: false, error: message } });
      return;
    }
    this.settlePendingServeRequest({
      action: pending.expectsAction ? { ok: false, error: message } : undefined,
      snapshot: { ok: false, error: message },
    });
  }

  /** serve への送信を直列化するチェーン内で run を実行する(自動フレームとユーザー操作の pending
   * スロット競合を防ぐ)。チェーン自体は常に成功状態を維持する(run の失敗を次回以降へ持ち越さない)。 */
  private enqueueServeSend<T>(run: () => Promise<T>): Promise<T> {
    const result = this.serveSendChain.then(run, run);
    this.serveSendChain = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** command を serve の stdin へ送り、対応する応答(actionResult[refresh以外]+snapshot)が
   * 揃うまで待つ。serve が起動していなければ CLI を呼ばずに即座にエラー結果を返す。
   * enqueueServeSend で直列化する(実体は sendServeCommandNow)。 */
  private sendServeCommand(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    return this.enqueueServeSend(() => this.sendServeCommandNow(command));
  }

  private sendServeCommandNow(command: LiveServeCommand): Promise<ServeRequestOutcome> {
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
      this.pendingServeRequest = {
        expectsAction: command.cmd !== "refresh",
        resolvesOn: "snapshot",
        action: undefined,
        resolve: (outcome) =>
          resolve({
            action: outcome.action,
            snapshot: outcome.snapshot ?? { ok: false, error: "内部エラー: snapshot が届きませんでした。" },
          }),
        timeout,
      };
      proc.stdin.write(serializeLiveServeCommand(command));
    });
  }

  /** 画像のみの frame コマンドを送る(自動リフレッシュ用)。serve が起動していなければ CLI を呼ばずに
   * 即座にエラー結果を返す(sendServeCommandNow と同じ文言)。enqueueServeSend で直列化する。 */
  private sendServeFrame(): Promise<LiveFrameResult> {
    return this.enqueueServeSend(() => this.sendServeFrameNow());
  }

  private sendServeFrameNow(): Promise<LiveFrameResult> {
    const proc = this.serveProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return Promise.resolve({
        ok: false,
        error: "ライブ操作の常駐プロセスが起動していません。デバイスを選び直してください。",
      });
    }
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        this.failPendingServeRequest("ライブ操作の応答がタイムアウトしました(常駐プロセスが応答していません)。");
      }, SERVE_REQUEST_TIMEOUT_MS);
      this.pendingServeRequest = {
        expectsAction: false,
        resolvesOn: "frame",
        action: undefined,
        resolve: (outcome) =>
          resolve(outcome.frame ?? { ok: false, error: "内部エラー: frame が届きませんでした。" }),
        timeout,
      };
      proc.stdin.write(serializeLiveServeCommand({ cmd: "frame" }));
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

  // ---- 自動フレーム(ライブタブ表示中、画像のみの定期更新) ------------------------------

  private clearFrameTimer(): void {
    if (this.frameTimer) {
      clearTimeout(this.frameTimer);
      this.frameTimer = undefined;
    }
  }

  private scheduleFrameTick(delayMs: number): void {
    if (this.frameTimer) {
      return;
    }
    this.frameTimer = setTimeout(() => {
      this.frameTimer = undefined;
      void this.frameTick();
    }, delayMs);
  }

  /** 表示中のみ回る自動フレーム。busy(ユーザー操作中)・パネル非表示・serve 不在の回はスキップ。
   * 失敗は表示しない(次tickで再試行。serve 死は既存の自動再起動が回復する)。
   * 成功時は待ちなしで次フレームへ(スキップ・失敗時のみ FRAME_IDLE_RETRY_MS 空ける)。 */
  private async frameTick(): Promise<void> {
    if (!this.liveTabVisible) {
      return;
    }
    let delayMs = FRAME_IDLE_RETRY_MS;
    if (this.deps.isPanelActive() && !this.busy && this.serveProcess && this.currentDeviceRef()) {
      const frame = await this.sendServeFrame();
      if (frame.ok) {
        this.post({ type: "frame", image: frame.image });
        delayMs = 0;
      }
    }
    if (this.liveTabVisible) {
      this.scheduleFrameTick(delayMs);
    }
  }

  // ---- tap/type/swipe/launch/terminate/install -------------------------------------

  /** serve へ1コマンド送って結果を反映する。成功時は serve が続けて返す観測イベント(操作後の
   * 追加待ちなしで届く。ブリッジ応答=UI整定済みのため)をそのまま画面へ反映する。失敗時は
   * 画面を再取得しない(観測イベント自体は届くが反映せず、直近のエラーを表示する)。 */
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

  private async refreshDevicesThenApps(): Promise<void> {
    await this.refreshDevices();
    await this.refreshAppsIfNeeded();
  }

  // ---- webview からのメッセージ -----------------------------------------------------
  // isLiveFromWebviewMessage による型ガードは呼び出し元(monitorPanel.ts の isLiveWebviewEnvelope)
  // 側で済んでいるためここでは行わない。

  handleWebviewMessage(message: LiveFromWebviewMessage): void {
    switch (message.type) {
      case "refreshDevices":
        void this.refreshDevicesThenApps();
        break;
      case "selectDevice":
        if (this.devices.some((device) => device.id === message.id)) {
          this.selectedDeviceId = message.id;
          this.ensureServeProcessForSelection();
          void this.refreshAppsIfNeeded();
        }
        break;
      case "refreshApps":
        void this.refreshApps();
        break;
      case "openDevice":
        void this.openDevice(message.id);
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
      case "dragPoints": {
        if (!this.lastScreen) {
          this.post({ type: "actionError", message: "先に「更新」で画面を取得してください。" });
          break;
        }
        const display = { width: message.displayWidth, height: message.displayHeight };
        const from = pointFromClick({ x: message.fromX, y: message.fromY }, display, this.lastScreen);
        const to = pointFromClick({ x: message.toX, y: message.toY }, display, this.lastScreen);
        // 実測時間をそのまま実機に流すと serve タイムアウト(20秒)に触れるためクランプする
        const pressSeconds = Math.min(Math.max(message.pressMs / 1000, 0), 3);
        const durationSeconds = Math.min(Math.max(message.dragMs / 1000, 0.05), 8);
        void this.runAction({
          cmd: "drag",
          fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
          press: pressSeconds, duration: durationSeconds,
        });
        break;
      }
      case "pressPoint": {
        if (!this.lastScreen) {
          this.post({ type: "actionError", message: "先に「更新」で画面を取得してください。" });
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        // 実測ホールド時間をそのまま流す(serve タイムアウト対策で 0.5〜5 秒にクランプ)
        const duration = Math.min(Math.max(message.holdMs / 1000, 0.5), 5);
        void this.runAction({ cmd: "press", x: point.x, y: point.y, duration });
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
      case "activate": {
        const bundleId = message.bundleId.trim();
        if (bundleId.length === 0) {
          this.post({ type: "actionError", message: "bundle ID / パッケージ名を入力してください。" });
          break;
        }
        void this.runAction({ cmd: "activate", bundle: bundleId });
        break;
      }
      case "appSwitcher":
        void this.runAction({ cmd: "appSwitcher" });
        break;
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
      case "visibility":
        this.liveTabVisible = message.visible;
        if (message.visible) {
          this.scheduleFrameTick(0);
        } else {
          this.clearFrameTimer();
        }
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
