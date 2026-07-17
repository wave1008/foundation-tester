// monitorDeviceOps.ts
// デバイスモニターパネル(monitorPanel.ts)のデバイスライフサイクル操作(起動/終了/新規作成)部分。
// pause/resume・マシンプロファイル最新化の通知は monitorProcessManager.ts/monitorProfilesController.ts
// を直接参照せず、MonitorPanelDeps 経由のコールバックで依頼する(サブコントローラ間の直接参照禁止)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable } from "node:stream";
import { resolveProjectName } from "./config";
import {
  bulkLifecycleOp,
  createDeviceLifecycleQueueState,
  finishDeviceLifecycleJob,
  type DeviceLifecycleJob,
  type DeviceLifecycleQueueState,
  deviceLifecycleJobNeedsMonitorPause,
  promoteDeviceLifecycleJobs,
  deviceLifecycleStatusFor,
  type DeviceOpKind,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isCreateDeviceEvent,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesRestartEvent,
  isDevicesUpEvent,
  removeQueuedBulkUpJob,
  isInstalledDevicesJson,
  type MonitorFromWebviewMessage,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { NdjsonParser } from "./ndjson";
import type { MonitorPanelDeps } from "./monitorPanel";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts の FtesterProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** webview からの "createDevice" メッセージの形(runCreateDevice で使う)。 */
export type CreateDeviceMessage = Extract<MonitorFromWebviewMessage, { type: "createDevice" }>;

/** monitorProfilesController.ts の handleMachineDeviceRemove(複数選択一括除去の確認文言)で使う。 */
export function summarizeDeviceNames(names: readonly string[]): string {
  const shown = names.slice(0, 3).join("、");
  return names.length > 3 ? `${shown} ほか` : shown;
}

/** デバイスライフサイクルの直列キューおよび device-catalog/installed-devices/create-device の
 * 短命プロセス実行を担う。MonitorPanelController が1つ保持する。 */
export class MonitorDeviceOps {
  /**
   * デバイスライフサイクル操作のスケジューラ。device ジョブは最大2台まで同時実行
   * (右クリック起動の2台並行=一括起動の2台固定ポリシーと同じ上限)、bulk/restartBatch は
   * 単独占有(内部で2台並行するため)。かつてブリッジ供給の並行実行が waitUntilReady 失敗・
   * ゾンビブリッジを誘発したため完全直列だったが、現在は ProvisionLock(クロスプロセス flock)が
   * 供給を直列化するので device ジョブの並行は安全。状態遷移(queued/running)の純粋ロジックは
   * monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();
  /** create-device の多重実行ガード。true の間に来た createDevice リクエストは即座に失敗を返す。 */
  private creatingDevice = false;
  /** 実行中の bulk up(devices-up)プロセス。「デバイスの起動を中断」の kill 対象。close で undefined に戻す。 */
  private bulkUpProc: PipeProcess | undefined;
  /** 凍結が治らず CPU 描画(swiftshader)へフォールバックしたデバイス論理名。セッション中維持
   * (host に戻すと再凍結するため)。個別 device-up 時に --gpu を付ける。bulk devices-up は
   * 別経路(executeBulkJob)のため対象外。 */
  private readonly cpuRenderNames = new Set<string>();

  constructor(private readonly deps: MonitorPanelDeps) {}

  /** ライフサイクルキューに実行中/待機中のジョブがあるか。watchdog が「一括down 実行中に
   * 無応答と誤検知して停止デバイスを再起動する」競合を避けるため、修復 up の抑止判定に使う。 */
  isQueueBusy(): boolean {
    return isDeviceLifecycleQueueBusy(this.lifecycleQueue);
  }

  /**
   * デバイスライフサイクル操作をキューに積む。空なら即実行、そうでなければ先行ジョブの完了後に
   * 実行される。同じデバイスへの deviceOp が既にキュー内(実行中/待機中)にあれば連打とみなして
   * 無視する(webview 側は `isDeviceLifecycleQueueBusy` でボタンを disabled にするため、通常は
   * ここに届く前に抑止される)。
   */
  enqueueLifecycleJob(job: DeviceLifecycleJob): void {
    if (job.kind === "device" && hasDeviceLifecycleJobFor(this.lifecycleQueue, job.name)) {
      return;
    }
    this.pushLifecycleJob(job);
  }

  /** ヘルスウォッチドッグの再起動修復: down→up を連続で積む。対象デバイスのジョブが既に
   * キューにあれば何もしない(enqueueLifecycleJob の連打対策と同じ理由。down と up のペアは
   * この直後の連続 push なので per-name 重複排除を素通しする)。 */
  enqueueRestart(name: string): void {
    if (hasDeviceLifecycleJobFor(this.lifecycleQueue, name)) {
      return;
    }
    this.pushLifecycleJob({ kind: "device", name, op: "down" });
    this.pushLifecycleJob({ kind: "device", name, op: "up" });
  }

  /** MonitorHealthWatchdogDeps.forceCpuRender への実装。以後この名前の device-up は
   * swiftshader で起動する(セッション中維持)。 */
  markCpuRender(name: string): void {
    this.cpuRenderNames.add(name);
  }

  /** 「GPUで再起動」(手動・右クリックメニュー): 単発もバッチジョブ(1件)として実行する。 */
  restartWithGpu(name: string): void {
    this.restartWithGpuBatch([name]);
  }

  /** 「デバイスを全て起動」: 未起動機のブートと CPU バッジ機の GPU 再起動を1ジョブ
   * (devices-up --restart)に統合して積む。CLI 側の単一キューを2ワーカーが消化するため、
   * 種別を問わず常に最大2台だけが起動処理中になる(2台同時でホスト CPU がほぼ飽和するため)。 */
  bulkUpWithRestarts(restartNames: readonly string[]): void {
    const targets = restartNames.filter((n) => !hasDeviceLifecycleJobFor(this.lifecycleQueue, n));
    for (const n of targets) {
      this.cpuRenderNames.delete(n);
    }
    this.enqueueLifecycleJob({ kind: "bulk", op: "up", restartNames: targets });
  }

  /** 「デバイスの起動を中断」: 実行中の bulk up プロセスを SIGTERM で止める。進行中(最大2台)の
   * ブート自体はエミュレータ/simctl が detach 済みのため完走しうる=中断の意味は「以降のデバイスへ
   * 進まない」。後始末(チップ剥がし・busy 解除・次ジョブ実行)は既存の close→finishLifecycleQueueHead
   * 経路が担う。キュー待ち(未実行)の bulk up はキューから除去する。 */
  cancelBulkUp(): void {
    const runningBulkUp = this.lifecycleQueue.running.some(
      (job) => job.kind === "bulk" && job.op === "up",
    );
    if (runningBulkUp) {
      if (this.bulkUpProc) {
        this.deps.outputChannel.appendLine("[ftester] デバイスの起動を中断します(devices-up へ SIGTERM)");
        this.bulkUpProc.kill("SIGTERM");
      }
      return;
    }
    const result = removeQueuedBulkUpJob(this.lifecycleQueue);
    if (result.removed) {
      this.lifecycleQueue = result.state;
      for (const n of result.removed.restartNames ?? []) {
        this.deps.post({ type: "deviceOpBusy", name: n, op: null, status: null });
      }
      this.postBootBusy();
      this.deps.outputChannel.appendLine("[ftester] キュー待ちの一括起動を取り消しました");
    }
  }

  /** CPU 描画フォールバックの記憶を解除し、devices-restart(2台ずつ並行の down→up)1ジョブで
   * まとめて再起動する。次回起動は --gpu が付かず host(GPU)。以後また画面凍結して watchdog の
   * 自動フォールバックが走れば CPU に戻る(既知のトレードオフ。docs/design.md §12.4)。
   * 直列キューに既に載っているデバイスは除外(連打防止の既存方針)。 */
  restartWithGpuBatch(names: readonly string[]): void {
    const targets = names.filter((n) => !hasDeviceLifecycleJobFor(this.lifecycleQueue, n));
    if (targets.length === 0) {
      return;
    }
    for (const n of targets) {
      this.cpuRenderNames.delete(n);
    }
    this.pushLifecycleJob({ kind: "restartBatch", names: targets });
  }

  /** enqueueLifecycleJob/enqueueRestart 共通のキュー投入処理(重複排除は呼び出し側の責務)。
   * 投入後にスケジューラを回し、開始できるジョブ(device は最大2並行)を即時開始する。 */
  private pushLifecycleJob(job: DeviceLifecycleJob): void {
    this.lifecycleQueue = enqueueDeviceLifecycleJob(this.lifecycleQueue, job);
    this.postBootBusy();
    this.postJobStatuses(job);
    this.scheduleLifecycleJobs();
  }

  /** ジョブ対象デバイスの queued/running バッジを再送する(投入直後・開始直後の表示更新)。 */
  private postJobStatuses(job: DeviceLifecycleJob): void {
    if (job.kind === "device") {
      this.postDeviceLifecycleStatus(job.name);
    } else if (job.kind === "restartBatch") {
      for (const n of job.names) {
        this.postDeviceLifecycleStatus(n);
      }
    } else {
      // 再起動待ちの CPU 機に「再起動待機中」を出す(無表示だと処理対象なのか分からない)。
      for (const n of job.restartNames ?? []) {
        this.postDeviceLifecycleStatus(n);
      }
    }
  }

  /** スケジューラ: 開始可能な待機ジョブを running へ昇格し、実処理を開始する。 */
  private scheduleLifecycleJobs(): void {
    const result = promoteDeviceLifecycleJobs(this.lifecycleQueue);
    this.lifecycleQueue = result.state;
    for (const job of result.started) {
      this.startLifecycleJob(job);
    }
  }

  /** キューの現在状態を bootBusy として webview に送る(busy=グローバルボタン無効化、
   * bulkOp=タイルの「待機中」/「シャットダウン中」表示)。キューが変化するたびに呼ぶ(上書き描画のみなので冪等)。 */
  private postBootBusy(): void {
    this.deps.post({
      type: "bootBusy",
      busy: isDeviceLifecycleQueueBusy(this.lifecycleQueue),
      bulkOp: bulkLifecycleOp(this.lifecycleQueue),
    });
  }

  /** 指定デバイスの現在のキュー状態(実行中/待機中/なし)を deviceOpBusy として webview に送る。 */
  private postDeviceLifecycleStatus(name: string): void {
    const status = deviceLifecycleStatusFor(this.lifecycleQueue, name);
    this.deps.post({ type: "deviceOpBusy", name, op: status?.op ?? null, status: status?.status ?? null });
  }

  /**
   * MonitorPanelController.sendInitialState() から呼ばれる: キュー状態を再送し、webview 再読込が
   * ジョブ実行中に起きた場合でもボタン無効化・タイルのバッジを復元する。ready は再読込のたびに
   * 再送されうるため、この処理は冪等でなければならない(webview 側は上書き描画のみなので問題ない)。
   */
  resendQueueStatus(): void {
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.postBootBusy();
    }
    for (const job of [...this.lifecycleQueue.running, ...this.lifecycleQueue.jobs]) {
      this.postJobStatuses(job);
    }
  }

  /** キュー先頭のジョブを実行する(devices up/down の一括実行、または device-up/down の個別実行)。 */
  /** モニター pause の参照カウント(down 系ジョブが同時に複数走るため。0→1 で pause、1→0 で resume)。 */
  private monitorPauseDepth = 0;

  private acquireMonitorPause(): void {
    this.monitorPauseDepth += 1;
    if (this.monitorPauseDepth === 1) {
      this.deps.writeMonitorControl({ cmd: "pause" });
    }
  }

  private releaseMonitorPause(): void {
    this.monitorPauseDepth = Math.max(0, this.monitorPauseDepth - 1);
    if (this.monitorPauseDepth === 0) {
      this.deps.writeMonitorControl({ cmd: "resume" });
    }
  }

  /** 1ジョブの実処理を開始する(scheduleLifecycleJobs が running へ昇格させた直後に呼ぶ)。 */
  private startLifecycleJob(job: DeviceLifecycleJob): void {
    // down 系ジョブは実行直前にモニターへ pause を送り、片付け中のデバイスへポーリングが
    // スクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系は起動進行を見せるので pause しない。
    if (deviceLifecycleJobNeedsMonitorPause(job)) {
      this.acquireMonitorPause();
    }
    if (job.kind === "bulk") {
      // down 実行直前にストリームを破棄し、simctl/adb に殺される前にタイルを切断表示へ倒す
      // (放置すると stall 自己修復[15-25秒]まで最終フレームが固まって見える)。
      if (job.op === "down") {
        this.deps.stopAllStreams();
      }
      this.postJobStatuses(job);
      this.executeBulkJob(job.op, job.restartNames ?? []);
    } else if (job.kind === "restartBatch") {
      // ストリームはここでは止めず、CLI の deviceStopping イベント受信時にそのデバイスだけ止める
      // (2台ずつ並行のため、まだ触れていないデバイスのライブ映像を先に消さない)。
      this.postJobStatuses(job);
      this.executeRestartBatchJob(job.names);
    } else {
      // 「実行中」バッジへ更新(running へ昇格済みのため statusFor が running を返す)。
      this.postDeviceLifecycleStatus(job.name);
      if (job.op === "down") {
        this.deps.stopDeviceStreams(job.name);
      }
      this.executeDeviceOpJob(job.name, job.op);
    }
  }

  /**
   * ジョブの完了後始末。running から取り除き、pause の参照を返し、対象デバイスのバッジを剥がして
   * スケジューラを回す(開始できる待機ジョブがあれば続けて実行する)。
   */
  private finishLifecycleJob(job: DeviceLifecycleJob): void {
    const result = finishDeviceLifecycleJob(this.lifecycleQueue, job);
    this.lifecycleQueue = result.state;
    const finished = result.removed;
    // pause した down 系ジョブは、成功・失敗を問わずここ(finally 相当)で参照を返す。
    if (deviceLifecycleJobNeedsMonitorPause(finished)) {
      this.releaseMonitorPause();
    }
    if (finished.kind === "device") {
      this.deps.post({ type: "deviceOpBusy", name: finished.name, op: null, status: null });
    } else if (finished.kind === "restartBatch") {
      // プロセスクラッシュ等で per-device の deviceFinished が欠けた場合の表示剥がし
      // (正常時は二重送信だが上書き描画のみなので無害)。
      for (const n of finished.names) {
        this.deps.post({ type: "deviceOpBusy", name: n, op: null, status: null });
      }
    } else {
      // bulk の restartNames も同様(deviceStopping 前にクラッシュすると「再起動待機中」が残る)。
      for (const n of finished.restartNames ?? []) {
        this.deps.post({ type: "deviceOpBusy", name: n, op: null, status: null });
      }
    }
    // bulk 完了時に bulkOp:null を届けて「待機中」/「シャットダウン中」表示を解除するため、空でなくても送る。
    this.postBootBusy();
    this.scheduleLifecycleJobs();
  }

  /**
   * `ftester devices up`/`devices down` を短命プロセスとして実行する(bulk ジョブの実処理)。
   * 選択中の実行プロファイル(ftester.profile)が非空なら --profile を付与し、対象を
   * そのプロファイルが参照するデバイスのみに限定する(空ならマシンプロファイルの全デバイス。
   * down も同様に --project/--profile を渡せる)。
   */
  private executeBulkJob(kind: "up" | "down", restartNames: readonly string[] = []): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    // up は ftester api devices-up(deviceStarting/deviceFinished の NDJSON でタイルを即時更新)、
    // down は従来どおり devices down(プレーンテキスト出力のみ)。
    const args: string[] = kind === "up" ? ["api", "devices-up"] : ["devices", kind];
    if (kind === "up") {
      // 起動済みでも down→up する対象(CPU バッジ機の GPU 復帰)。未起動機のブートと同一キューで
      // 2台ずつ並行処理される(DeviceBooter.bootAll の restartNames)。
      for (const n of restartNames) {
        args.push("--restart", n);
      }
    }
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }
    if (config.profile) {
      args.push("--profile", config.profile);
    }

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // finishLifecycleQueueHead() はキュー先頭を1回だけ取り除く前提なので、二重呼び出しを防ぐ。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleJob({ kind: "bulk", op: kind });
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] devices ${kind} の起動に失敗しました: ${String(error)}`);
      finishOnce();
      return;
    }
    if (kind === "up") {
      // 「デバイスの起動を中断」(cancelBulkUp)の kill 対象として保持。close で解除。
      this.bulkUpProc = proc;
      proc.on("close", () => {
        if (this.bulkUpProc === proc) {
          this.bulkUpProc = undefined;
        }
      });
    }

    const appendLines = (stream: "stdout" | "stderr", chunk: Buffer): void => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          this.deps.outputChannel.appendLine(`[devices ${kind} ${stream}] ${line}`);
        }
      }
    };

    if (kind === "down") {
      proc.stdout.on("data", (chunk: Buffer) => appendLines("stdout", chunk));
      proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

      proc.on("error", (error) => {
        this.deps.outputChannel.appendLine(
          `[ftester] devices ${kind} の実行でエラーが発生しました: ${error.message}`,
        );
        finishOnce();
      });
      proc.on("close", (exitCode) => {
        this.deps.outputChannel.appendLine(
          `[ftester] devices ${kind} が終了しました(exit code: ${String(exitCode)})`,
        );
        finishOnce();
      });
      return;
    }

    // ---- up 専用経路: devices-up の NDJSON を中継し、deviceStarting/deviceFinished から
    // 即座にタイルの「起動中」表示を作る(モニターの状態スキャン到達を待たない)。stderr は
    // devices-up の診断ログのみなので down と同じプレーンテキスト出力のまま。----

    // このジョブのクロージャ内だけで有効な「起動を掴んだがまだ完了していないデバイス名」集合。
    // close 時に残っていればクラッシュ・kill とみなし、deviceOpBusy(null) で表示を剥がす
    // (正常終了なら deviceFinished で空になっているはずなので no-op)。
    const startedNames = new Set<string>();
    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDevicesUpEvent(value)) {
          this.deps.outputChannel.appendLine(
            `[devices up] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        switch (value.kind) {
          case "log":
            this.deps.outputChannel.appendLine(`[devices up] ${value.message}`);
            break;
          case "deviceStopping":
            // --restart 対象の down 開始。ストリームをこのデバイスだけ止める(simctl/adb に殺される前に
            // タイルを切断表示へ倒す。他デバイスのライブ映像は残す)。
            startedNames.add(value.name);
            this.deps.stopDeviceStreams(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: "down", status: "running" });
            break;
          case "deviceStarting":
            startedNames.add(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: "up", status: "running" });
            break;
          case "deviceFinished":
            startedNames.delete(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: null, status: null });
            break;
          case "finished":
            if (!value.ok) {
              this.deps.outputChannel.appendLine(
                `[ftester] devices up が失敗しました: ${value.error ?? "(詳細不明)"}`,
              );
            }
            break;
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[devices up stdout] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        `[ftester] devices ${kind} の実行でエラーが発生しました: ${error.message}`,
      );
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      // クラッシュ・kill でタイルの「起動中」表示が永久に残らないためのクリーンアップ
      // (正常終了なら deviceFinished 済みでこの Set は空 = 無害な no-op)。
      for (const name of startedNames) {
        this.deps.post({ type: "deviceOpBusy", name, op: null, status: null });
      }
      startedNames.clear();
      this.deps.outputChannel.appendLine(
        `[ftester] devices ${kind} が終了しました(exit code: ${String(exitCode)})`,
      );
      finishOnce();
    });
  }

  /**
   * `ftester api devices-restart` を短命プロセスとして実行する(restartBatch ジョブの実処理)。
   * CLI 側が 2 台ずつ並行で down→up し、per-device の deviceStopping/deviceStarting/deviceFinished
   * NDJSON を流す(契約: monitorModel.ts isDevicesRestartEvent / Sources/ftester/ApiDeviceCommands.swift)。
   * 全体の構造(spawn 例外・'error'+'close' 二重発火の finishOnce ガード・close 時の表示剥がし)は
   * executeBulkJob の up 経路と同じ。
   */
  private executeRestartBatchJob(names: readonly string[]): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const args: string[] = ["api", "devices-restart"];
    for (const n of names) {
      args.push("--name", n);
    }
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }
    // machine 解決に使う(executeDeviceOpJob と同じ理由。ApiDevicesRestart 側の --profile と対)。
    if (config.profile) {
      args.push("--profile", config.profile);
    }

    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleJob({ kind: "restartBatch", names });
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(`[ftester] devices-restart の起動に失敗しました: ${String(error)}`);
      finishOnce();
      return;
    }

    // 「down/up を掴んだがまだ完了していないデバイス名」。close 時に残っていればクラッシュ・kill と
    // みなし表示を剥がす(executeBulkJob の startedNames と同じ目的)。
    const busyNames = new Set<string>();
    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDevicesRestartEvent(value)) {
          this.deps.outputChannel.appendLine(
            `[devices-restart] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        switch (value.kind) {
          case "log":
            this.deps.outputChannel.appendLine(`[devices-restart] ${value.message}`);
            break;
          case "deviceStopping":
            // このデバイスの down が始まる。ストリームをここで止める(simctl/adb に殺される前に
            // タイルを切断表示へ倒す。バッチ開始時に全台止めない理由は runLifecycleQueueHead 参照)。
            busyNames.add(value.name);
            this.deps.stopDeviceStreams(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: "down", status: "running" });
            break;
          case "deviceStarting":
            busyNames.add(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: "up", status: "running" });
            break;
          case "deviceFinished":
            busyNames.delete(value.name);
            this.deps.post({ type: "deviceOpBusy", name: value.name, op: null, status: null });
            break;
          case "finished":
            if (!value.ok) {
              this.deps.outputChannel.appendLine(
                `[ftester] devices-restart が失敗しました: ${value.error ?? "(詳細不明)"}`,
              );
            }
            break;
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[devices-restart stdout] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          this.deps.outputChannel.appendLine(`[devices-restart stderr] ${line}`);
        }
      }
    });

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        `[ftester] devices-restart の実行でエラーが発生しました: ${error.message}`,
      );
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      for (const name of busyNames) {
        this.deps.post({ type: "deviceOpBusy", name, op: null, status: null });
      }
      busyNames.clear();
      this.deps.outputChannel.appendLine(
        `[ftester] devices-restart が終了しました(exit code: ${String(exitCode)})`,
      );
      finishOnce();
    });
  }

  /** up が失敗したときの追加試行回数(計 1+2=3 回)。再起動(down→up)の up が転けてデバイスが
   * 下がったまま放置される事故を防ぐ。watchdog は offline/消失を blank-screen として拾えず
   * 二度と復旧しないため、この経路で確実に復帰を試みる。down は再試行しない(消したいだけなので)。 */
  private static readonly deviceUpMaxRetries = 2;
  /** up 再試行の間隔(ミリ秒)。直前の失敗した起動/adb を落ち着かせてから再スポーンする。 */
  private static readonly deviceUpRetryDelayMs = 3000;

  /**
   * タイル右クリックメニューの起動/停止項目・再起動(down→up)から、デバイス1台だけを
   * `ftester api device-up`/`device-down` で起動/停止する(device ジョブの実処理)。
   * up が失敗した場合は deviceUpMaxRetries まで再試行してからキューを進める。
   * 失敗時(finished ok:false、または finished を出せずに落ちた場合を含む)は、バナーがパネルを
   * 閉じると消えるため、事後診断できるよう出力チャネルにも必ずログを残す。
   */
  private executeDeviceOpJob(name: string, op: DeviceOpKind): void {
    // spawn 失敗時の 'error'+'close' 二重発火・複数試行にまたがる finish の二重呼び出しを防ぐ
    // ジョブ単位のガード(finishLifecycleQueueHead は1ジョブにつき1回だけ呼ぶ)。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleJob({ kind: "device", name, op });
    };
    this.runDeviceOpAttempt(name, op, 0, finishOnce);
  }

  /** device-up/down の1回分の実行。up が失敗し追加試行が残っていれば遅延後に再試行、
   * それ以外(成功・down・up の上限到達)は finishOnce でキューを進める。 */
  private runDeviceOpAttempt(name: string, op: DeviceOpKind, attempt: number, finishOnce: () => void): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const args: string[] = ["api", op === "up" ? "device-up" : "device-down", "--name", name];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }
    // machine 解決に使う。実行プロファイルの machine 指定を determineMachine が最優先で採用するため、
    // これが無いと machines/ が複数のとき「マシン名が未登録」で落ちてブリッジ供給に到達しない
    // (executeBulkJob と同経路。ApiDeviceUp/Down 側の --profile と対)。
    if (config.profile) {
      args.push("--profile", config.profile);
    }
    if (op === "up" && this.cpuRenderNames.has(name)) {
      args.push("--gpu", "swiftshader_indirect");
    }

    const attemptLabel = attempt > 0 ? `(再試行 ${attempt}/${MonitorDeviceOps.deviceUpMaxRetries})` : "";
    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.deps.outputChannel.appendLine(`[ftester] device-${op}(${name})が失敗しました${attemptLabel}: ${message}`);
    };

    // この試行の終端('error' と 'close' の二重発火を1回に集約)。up が失敗し追加試行が残っていれば
    // 再試行(キューは進めない)、それ以外は finishOnce。
    let attemptSettled = false;
    const settle = (failed: boolean): void => {
      if (attemptSettled) {
        return;
      }
      attemptSettled = true;
      if (failed && op === "up" && attempt < MonitorDeviceOps.deviceUpMaxRetries) {
        this.deps.outputChannel.appendLine(
          `[ftester] device-up(${name})を再試行します(${attempt + 1}/${MonitorDeviceOps.deviceUpMaxRetries}、`
            + `${MonitorDeviceOps.deviceUpRetryDelayMs}ms 後)`,
        );
        setTimeout(
          () => this.runDeviceOpAttempt(name, op, attempt + 1, finishOnce),
          MonitorDeviceOps.deviceUpRetryDelayMs,
        );
        return;
      }
      finishOnce();
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      logFailure(String(error));
      this.deps.post({ type: "deviceOpFailed", name, message: String(error) });
      settle(true);
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDeviceOpEvent(value)) {
          this.deps.outputChannel.appendLine(
            `[device-${op} ${name}] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[device-${op} ${name}] ${value.message}`);
        } else if (!value.ok) {
          const message = value.error ?? `device-${op} に失敗しました。`;
          logFailure(message);
          this.deps.post({ type: "deviceOpFailed", name, message });
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[device-${op} ${name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[device-${op} ${name} stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[device-${op} ${name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      logFailure(error.message);
      this.deps.post({ type: "deviceOpFailed", name, message: error.message });
      settle(true);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        `[ftester] device-${op}(${name})が終了しました${attemptLabel}(exit code: ${String(exitCode)})`,
      );
      // finished(ok:false)を経由せずに落ちたケース(クラッシュ・kill 等)を捕捉する。
      // finished 経由で既にログ済みの場合は二重に出さない。
      if (!failureLogged && exitCode !== 0) {
        logFailure(`プロセスが exit code ${String(exitCode)} で終了しました`);
      }
      settle(failureLogged);
    });
  }

  // ---- マシンプロファイル(プロファイルタブ): デバイスカタログ取得・デバイス追加 -----------------
  // いずれもデバイスライフサイクルの直列キュー(lifecycleQueue)には載せない —
  // device-catalog は単なる参照系の単発コマンド、create-device もモーダル側の1件実行ガード
  // (creatingDevice)で十分であり、simctl/adb 起動系のキューと競合する処理ではないため。

  /**
   * `ftester api device-catalog` を短命プロセスとして実行し、結果を webview へ返す。
   * 多重リクエストはボタン側(モーダルは開いた直後に1回だけ送る)で抑止する前提のため、
   * ここでは単純に都度実行する。stdout を全量蓄積し、close 時にまとめて JSON.parse する
   * (単発 JSON 1行の出力なので NDJSON パーサは不要)。
   */
  runDeviceCatalog(): void {
    const config = this.deps.getConfig();

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "device-catalog"], {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = `device-catalog の起動に失敗しました: ${String(error)}`;
      this.deps.outputChannel.appendLine(`[ftester] ${message}`);
      this.deps.post({ type: "deviceCatalog", ok: false, catalog: null, error: message });
      return;
    }

    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    // spawn 失敗時の 'error'+'close' 二重発火対策(executeBulkJob 参照)。二重 post を防ぐ。
    let responded = false;
    const respond = (message: MonitorToWebviewMessage): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.deps.post(message);
    };
    const flushStderr = (): void => {
      const trimmed = stderr.trim();
      if (trimmed.length > 0) {
        this.deps.outputChannel.appendLine(`[device-catalog stderr] ${trimmed}`);
      }
    };

    proc.on("error", (error) => {
      const message = `device-catalog の実行でエラーが発生しました: ${error.message}`;
      this.deps.outputChannel.appendLine(`[ftester] ${message}`);
      flushStderr();
      respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const message = `device-catalog が失敗しました(exit code: ${String(exitCode)})`;
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = `device-catalog の出力を解析できませんでした: ${String(error)}`;
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      if (!isDeviceCatalogJson(parsed)) {
        const message = "device-catalog の出力形式が不正です。";
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      respond({ type: "deviceCatalog", ok: true, catalog: parsed, error: null });
    });
  }

  /**
   * `ftester api installed-devices` を短命プロセスとして実行し、結果を webview へ返す
   * (「+既存から選択」モーダルが開いた直後の installedDevicesRequest への応答。runDeviceCatalog と
   * 全く同じ短命 spawn パターン — 単発 JSON 1行の出力を全量蓄積して close 時にまとめて
   * JSON.parse する)。
   */
  runInstalledDevices(): void {
    const config = this.deps.getConfig();

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", "installed-devices"], {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = `installed-devices の起動に失敗しました: ${String(error)}`;
      this.deps.outputChannel.appendLine(`[ftester] ${message}`);
      this.deps.post({ type: "installedDevices", ok: false, data: null, error: message });
      return;
    }

    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    let responded = false;
    const respond = (message: MonitorToWebviewMessage): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.deps.post(message);
    };
    const flushStderr = (): void => {
      const trimmed = stderr.trim();
      if (trimmed.length > 0) {
        this.deps.outputChannel.appendLine(`[installed-devices stderr] ${trimmed}`);
      }
    };

    proc.on("error", (error) => {
      const message = `installed-devices の実行でエラーが発生しました: ${error.message}`;
      this.deps.outputChannel.appendLine(`[ftester] ${message}`);
      flushStderr();
      respond({ type: "installedDevices", ok: false, data: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const message = `installed-devices が失敗しました(exit code: ${String(exitCode)})`;
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = `installed-devices の出力を解析できませんでした: ${String(error)}`;
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      if (!isInstalledDevicesJson(parsed)) {
        const message = "installed-devices の出力形式が不正です。";
        this.deps.outputChannel.appendLine(`[ftester] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      respond({ type: "installedDevices", ok: true, data: parsed, error: null });
    });
  }

  /**
   * `ftester api create-device` を短命プロセスとして実行する(デバイス追加モーダルの OK)。
   * creatingDevice による多重実行防止(モーダル側のボタン無効化に加えた保険)。finished が来る前に
   * プロセスが落ちた場合は合成の失敗結果を送る(executeDeviceOpJob と同じパターン)。成功時は
   * FileSystemWatcher 経由でも postMachineProfileInfo() が呼ばれるが、反映を待たせないようここでも
   * MonitorPanelDeps.notifyMachineProfilesChanged 経由で明示的に呼ぶ(冪等なので二重呼び出しは無害)。
   * msg.register が false のときは `--no-register` を付与し物理作成のみ行う(マシンプロファイルには
   * 追記しない。#device-pick-overlay の「+」新規作成モーダルが使う)。
   */
  runCreateDevice(msg: CreateDeviceMessage): void {
    if (this.creatingDevice) {
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: "作成処理が既に実行中です。",
        device: null,
      });
      return;
    }
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.deps.post({
        type: "createDeviceResult",
        ok: false,
        name: msg.name,
        error: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        device: null,
      });
      return;
    }
    const args = [
      "api",
      "create-device",
      "--project",
      resolution.project,
      "--machine",
      msg.machine,
      "--platform",
      msg.platform,
      "--name",
      msg.name,
      "--model",
      msg.model,
      "--os",
      msg.os,
    ];
    if (!msg.register) {
      args.push("--no-register");
    }

    this.creatingDevice = true;
    let responded = false;
    const respond = (
      ok: boolean,
      error: string | null,
      device: { avd: string | null; udid: string | null } | null,
    ): void => {
      if (responded) {
        return;
      }
      responded = true;
      this.creatingDevice = false;
      this.deps.post({ type: "createDeviceResult", ok, name: msg.name, error, device });
      if (ok) {
        this.deps.notifyMachineProfilesChanged();
      }
    };

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})の起動に失敗しました: ${String(error)}`,
      );
      respond(false, String(error), null);
      return;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isCreateDeviceEvent(value)) {
          this.deps.outputChannel.appendLine(
            `[create-device ${msg.name}] 未知の形式の行を無視しました: ${JSON.stringify(value)}`,
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[create-device ${msg.name}] ${value.message}`);
        } else {
          if (!value.ok) {
            this.deps.outputChannel.appendLine(
              `[ftester] create-device(${msg.name})が失敗しました: ${value.error ?? "(詳細不明)"}`,
            );
          }
          respond(value.ok, value.error, value.device ? { avd: value.device.avd, udid: value.device.udid } : null);
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[create-device ${msg.name} stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[create-device ${msg.name} stderr] ${line}`),
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})の実行でエラーが発生しました: ${error.message}`,
      );
      respond(false, error.message, null);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        `[ftester] create-device(${msg.name})が終了しました(exit code: ${String(exitCode)})`,
      );
      // finished を経由せず落ちた場合の合成失敗(executeDeviceOpJob と同じパターン。responded ガードで二重防止)。
      respond(false, `プロセスが exit code ${String(exitCode)} で終了しました`, null);
    });
  }
}
