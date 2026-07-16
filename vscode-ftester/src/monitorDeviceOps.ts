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
  dequeueDeviceLifecycleJob,
  type DeviceLifecycleJob,
  type DeviceLifecycleQueueState,
  deviceLifecycleJobNeedsMonitorPause,
  deviceLifecycleQueueHead,
  deviceLifecycleStatusFor,
  type DeviceOpKind,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isCreateDeviceEvent,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesUpEvent,
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
   * デバイスライフサイクル操作(全起動/終了・個別 device-up/down)の直列キュー。ブリッジ供給・
   * simctl・adb が競合しないよう必ず1件ずつ実行する(実機ログ解析: 並行実行がブリッジ供給の
   * waitUntilReady 失敗・ゾンビブリッジ蓄積を誘発していた)。状態遷移(queued/running)の純粋
   * ロジックは monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();
  /** create-device の多重実行ガード。true の間に来た createDevice リクエストは即座に失敗を返す。 */
  private creatingDevice = false;

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

  /** enqueueLifecycleJob/enqueueRestart 共通のキュー投入処理(重複排除は呼び出し側の責務)。 */
  private pushLifecycleJob(job: DeviceLifecycleJob): void {
    const wasBusy = isDeviceLifecycleQueueBusy(this.lifecycleQueue);
    this.lifecycleQueue = enqueueDeviceLifecycleJob(this.lifecycleQueue, job);
    this.postBootBusy();
    if (!wasBusy) {
      this.runLifecycleQueueHead();
    } else if (job.kind === "device") {
      this.postDeviceLifecycleStatus(job.name);
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
    for (const job of this.lifecycleQueue.jobs) {
      if (job.kind === "device") {
        this.postDeviceLifecycleStatus(job.name);
      }
    }
  }

  /** キュー先頭のジョブを実行する(devices up/down の一括実行、または device-up/down の個別実行)。 */
  private runLifecycleQueueHead(): void {
    const job = deviceLifecycleQueueHead(this.lifecycleQueue);
    if (!job) {
      return;
    }
    // down 系ジョブ(bulk down / device-down)は実行直前にモニターへ pause を送り、片付け中の
    // デバイスへポーリングがスクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系は起動進行を
    // タイルで見たいので pause しない。
    if (deviceLifecycleJobNeedsMonitorPause(job)) {
      this.deps.writeMonitorControl({ cmd: "pause" });
    }
    if (job.kind === "bulk") {
      // down 実行直前にストリームを破棄し、simctl/adb に殺される前にタイルを切断表示へ倒す
      // (放置すると stall 自己修復[15-25秒]まで最終フレームが固まって見える)。
      if (job.op === "down") {
        this.deps.stopAllStreams();
      }
      this.executeBulkJob(job.op);
    } else {
      // 待機中だったジョブがここで先頭に回ってきた場合も含め、「実行中」バッジに更新する。
      this.postDeviceLifecycleStatus(job.name);
      if (job.op === "down") {
        this.deps.stopDeviceStreams(job.name);
      }
      this.executeDeviceOpJob(job.name, job.op);
    }
  }

  /**
   * 先頭ジョブの完了後始末。キューから取り除き、残りがあれば続けて次を実行し、
   * 空になったらグローバルボタンの busy 状態を解除する。
   */
  private finishLifecycleQueueHead(): void {
    const finished = deviceLifecycleQueueHead(this.lifecycleQueue);
    // pause した down 系ジョブは、成功・失敗を問わずここ(finally 相当)でモニターを resume する。
    if (finished && deviceLifecycleJobNeedsMonitorPause(finished)) {
      this.deps.writeMonitorControl({ cmd: "resume" });
    }
    this.lifecycleQueue = dequeueDeviceLifecycleJob(this.lifecycleQueue);
    if (finished?.kind === "device") {
      this.deps.post({ type: "deviceOpBusy", name: finished.name, op: null, status: null });
    }
    // bulk 完了時に bulkOp:null を届けて「待機中」/「シャットダウン中」表示を解除するため、空でなくても送る。
    this.postBootBusy();
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.runLifecycleQueueHead();
    }
  }

  /**
   * `ftester devices up`/`devices down` を短命プロセスとして実行する(bulk ジョブの実処理)。
   * 選択中の実行プロファイル(ftester.profile)が非空なら --profile を付与し、対象を
   * そのプロファイルが参照するデバイスのみに限定する(空ならマシンプロファイルの全デバイス。
   * down も同様に --project/--profile を渡せる)。
   */
  private executeBulkJob(kind: "up" | "down"): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    // up は ftester api devices-up(deviceStarting/deviceFinished の NDJSON でタイルを即時更新)、
    // down は従来どおり devices down(プレーンテキスト出力のみ)。
    const args: string[] = kind === "up" ? ["api", "devices-up"] : ["devices", kind];
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
      this.finishLifecycleQueueHead();
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
   * タイル右クリックメニューの起動/停止項目から、デバイス1台だけを
   * `ftester api device-up`/`device-down` で起動/停止する(device ジョブの実処理)。
   * 失敗時(finished ok:false、または finished を出せずに落ちた場合を含む)は、バナーがパネルを
   * 閉じると消えるため、事後診断できるよう出力チャネルにも必ずログを残す。
   */
  private executeDeviceOpJob(name: string, op: DeviceOpKind): void {
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

    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.deps.outputChannel.appendLine(`[ftester] device-${op}(${name})が失敗しました: ${message}`);
    };

    // spawn 失敗時の 'error'+'close' 二重発火対策(executeBulkJob と同じ理由)。
    let jobFinished = false;
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.finishLifecycleQueueHead();
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
      finishOnce();
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
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      this.deps.outputChannel.appendLine(
        `[ftester] device-${op}(${name})が終了しました(exit code: ${String(exitCode)})`,
      );
      // finished(ok:false)を経由せずに落ちたケース(クラッシュ・kill 等)を捕捉する。
      // finished 経由で既にログ済みの場合は二重に出さない。
      if (!failureLogged && exitCode !== 0) {
        logFailure(`プロセスが exit code ${String(exitCode)} で終了しました`);
      }
      finishOnce();
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
