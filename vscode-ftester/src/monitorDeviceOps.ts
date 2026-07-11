// monitorDeviceOps.ts
// デバイスモニターパネル(monitorPanel.ts)のデバイスライフサイクル操作(起動/終了/新規作成)部分。
// MonitorDeviceOps クラスは、デバイスの起動/終了の直列キュー(devicesUp/devicesDown/deviceOp)・
// デバイスカタログ取得・インストール済みデバイス一覧取得・新規デバイス作成(いずれも短命プロセスの
// spawn)を担う。モニタープロセスの pause/resume(writeMonitorControl)・マシンプロファイル最新化の
// 通知は、このクラスからは monitorProcessManager.ts / monitorProfilesController.ts を直接参照せず、
// MonitorPanelDeps 経由のコールバックで依頼する(サブコントローラ間の直接参照禁止のため)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable } from "node:stream";
import { resolveProjectName } from "./config";
import {
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

/**
 * 確認モーダルに列挙する対象デバイス名の文字列(「、」区切りで最大3件+超過分は「 ほか」)。
 * monitorProfilesController.ts の handleMachineDeviceRemove の複数選択一括除去の確認文言で使う。
 */
export function summarizeDeviceNames(names: readonly string[]): string {
  const shown = names.slice(0, 3).join("、");
  return names.length > 3 ? `${shown} ほか` : shown;
}

/**
 * デバイスライフサイクル操作(「デバイスを全て起動/終了」とタイル個別の device-up/device-down)の
 * 直列キュー、および device-catalog/installed-devices/create-device の短命プロセス実行を担う。
 * MonitorPanelController が1つ保持し、handleWebviewMessage の各ケースから公開メソッドを呼び出す。
 */
export class MonitorDeviceOps {
  /**
   * デバイスライフサイクル操作(「デバイスを全て起動/終了」とタイル個別の device-up/device-down)の
   * 直列キュー。ブリッジ供給・simctl・adb が競合しないよう、必ず1件ずつ実行する(実機ログ解析:
   * 並行実行がブリッジ供給の waitUntilReady 失敗・ゾンビブリッジ蓄積を誘発していた)。
   * 状態遷移(queued/running)の純粋ロジックは monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();
  /** create-device の多重実行ガード。true の間に来た createDevice リクエストは即座に失敗を返す。 */
  private creatingDevice = false;

  constructor(private readonly deps: MonitorPanelDeps) {}

  /**
   * デバイスライフサイクル操作(devicesUp/devicesDown/deviceOp)をキューに積む。
   * キューが空(何も実行中でない)ならそのまま実行を開始し、そうでなければ先に積まれている
   * ジョブの完了後に順番に実行される。同じデバイスへの deviceOp が既にキュー内(実行中または
   * 待機中)にある場合は連打とみなして無視する(グローバルボタン側は呼び出し元
   * (handleWebviewMessage 経由)では素通しだが、`isDeviceLifecycleQueueBusy` を見て webview 側の
   * ボタンが disabled になっているため、通常はここに届く前に抑止される)。
   */
  enqueueLifecycleJob(job: DeviceLifecycleJob): void {
    if (job.kind === "device" && hasDeviceLifecycleJobFor(this.lifecycleQueue, job.name)) {
      return;
    }
    const wasBusy = isDeviceLifecycleQueueBusy(this.lifecycleQueue);
    this.lifecycleQueue = enqueueDeviceLifecycleJob(this.lifecycleQueue, job);
    if (!wasBusy) {
      // キューが空だったので、このジョブがそのまま先頭になり即実行される。
      this.deps.post({ type: "bootBusy", busy: true });
      this.runLifecycleQueueHead();
    } else if (job.kind === "device") {
      // 何か実行中/待機中なので、このジョブは順番待ち(「待機中...」バッジ)になる。
      this.postDeviceLifecycleStatus(job.name);
    }
  }

  /** 指定デバイスの現在のキュー状態(実行中/待機中/なし)を deviceOpBusy として webview に送る。 */
  private postDeviceLifecycleStatus(name: string): void {
    const status = deviceLifecycleStatusFor(this.lifecycleQueue, name);
    this.deps.post({ type: "deviceOpBusy", name, op: status?.op ?? null, status: status?.status ?? null });
  }

  /**
   * webview からの "ready"(初期化完了通知)を受けた MonitorPanelController.sendInitialState() から
   * 呼ばれる: デバイスライフサイクルキューの状態を再送する(webview 再読込がジョブ実行中に起きた
   * 場合に、ボタンの無効状態・タイルのバッジを復元するため)。ready は webview 再読込のたびに
   * 再送されうるので、ここで行う処理が冪等であることが前提になる(webview 側で上書き描画するだけ
   * なので何度呼んでも問題ない)。
   */
  resendQueueStatus(): void {
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.deps.post({ type: "bootBusy", busy: true });
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
      this.deps.writeMonitorControl("pause");
    }
    if (job.kind === "bulk") {
      this.executeBulkJob(job.op);
    } else {
      // 待機中だったジョブがここで先頭に回ってきた場合も含め、「実行中」バッジに更新する。
      this.postDeviceLifecycleStatus(job.name);
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
      this.deps.writeMonitorControl("resume");
    }
    this.lifecycleQueue = dequeueDeviceLifecycleJob(this.lifecycleQueue);
    if (finished?.kind === "device") {
      this.deps.post({ type: "deviceOpBusy", name: finished.name, op: null, status: null });
    }
    if (isDeviceLifecycleQueueBusy(this.lifecycleQueue)) {
      this.runLifecycleQueueHead();
    } else {
      this.deps.post({ type: "bootBusy", busy: false });
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
    const args: string[] = ["devices", kind];
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
  }

  /**
   * タイル右クリックメニューの起動/停止項目から、デバイス1台だけを
   * `ftester api device-up`/`device-down` で起動/停止する(device ジョブの実処理)。
   * finished イベントが ok:false のとき、およびプロセスが異常終了したとき(finished を出せずに
   * 落ちた場合を含む)は、webview のエラーバナーに加えて出力チャネルにも必ずログを残す
   * (バナーはパネルを閉じると消えるため、事後診断できるよう出力チャネル側にも記録する)。
   */
  private executeDeviceOpJob(name: string, op: DeviceOpKind): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const args: string[] = ["api", op === "up" ? "device-up" : "device-down", "--name", name];
    if (resolution.kind === "resolved") {
      args.push("--project", resolution.project);
    }

    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.deps.outputChannel.appendLine(`[ftester] device-${op}(${name})が失敗しました: ${message}`);
    };

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

    // spawn 失敗時(ENOENT 等)は 'error' の後に 'close' も発火することがある(Node の既知の挙動)。
    // 二重に post しないようにガードする(executeDeviceOpJob の finishOnce パターンと同じ)。
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
   * creatingDevice フラグによる単一実行ガード(実行中に来たリクエストは即座に失敗を返す。
   * モーダル側も自身の作成中状態でボタンを無効化するが、二重の安全策として host 側でも弾く)。
   * finished イベントが来る前にプロセスが終了した場合(クラッシュ等)は合成の失敗結果を送る
   * (executeDeviceOpJob の finishOnce パターンと同じ)。成功時は、machines/*.json の
   * FileSystemWatcher(onDidChange)経由でも postMachineProfileInfo() が呼ばれるが、
   * 反映を待たせないようここでも明示的に呼ぶ(冪等なので二重呼び出しは無害。
   * monitorProfilesController.ts の MonitorProfilesController を直接参照せず、
   * MonitorPanelDeps.notifyMachineProfilesChanged 経由で依頼する)。
   * msg.register が false の場合は `--no-register` を付与し、物理作成のみ行う(マシンプロファイルへの
   * 追記はしない。#device-pick-overlay の「+」から開いた新規作成モーダルが使う)。
   * この場合 postMachineProfileInfo() を呼んでも(何も追記されていないため)実質的に無意味だが、
   * register:true と分岐を分けるほどの理由が無いため呼び出し自体は共通のままにしている。
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
      // finished を経由せずに落ちたケース(クラッシュ・kill 等)を合成の失敗として扱う。
      // finished 経由で既に respond 済みの場合は no-op(responded ガード)。
      respond(false, `プロセスが exit code ${String(exitCode)} で終了しました`, null);
    });
  }
}
