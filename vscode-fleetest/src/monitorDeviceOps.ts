// monitorDeviceOps.ts
// デバイスモニターパネル(monitorPanel.ts)のデバイスライフサイクル操作(起動/終了/新規作成)部分。
// pause/resume・プロジェクトのデバイスカタログ最新化の通知は monitorProcessManager.ts/monitorProfilesController.ts
// を直接参照せず、MonitorPanelDeps 経由のコールバックで依頼する(サブコントローラ間の直接参照禁止)。
// デバイスの新規作成/削除(create-device・delete-device・install-system-image)は
// monitorDeviceCreateOps.ts の MonitorDeviceCreateOps へ委譲する。文言組み立ての純粋関数は
// monitorDeviceOpsText.ts。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable } from "node:stream";
import * as vscode from "vscode";
import { childEnv } from "./childEnv";
import { resolveProjectName } from "./config";
import { t } from "./i18n";
import {
  bulkLifecycleOp,
  createDeviceLifecycleQueueState,
  finishDeviceLifecycleJob,
  type DeviceLifecycleJob,
  type DeviceLifecycleQueueState,
  deviceLifecycleJobNeedsMonitorPause,
  promoteDeviceLifecycleJobs,
  deviceLifecycleStatusFor,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesRestartEvent,
  isDevicesUpEvent,
  removeQueuedBulkUpJob,
  removeQueuedDeviceUpJob,
  isInstalledDevicesJson,
  type MonitorDevice,
  type MonitorFromWebviewMessage,
  type MonitorToWebviewMessage,
} from "./monitorModel";
import { sweepRefusalDetail } from "./machineLockModel";
import { NdjsonParser } from "./ndjson";
import { DeviceActionNotices } from "./monitorDeviceActionNotice";
import type { MonitorPanelDeps } from "./monitorPanel";
import { type DeviceCommandSource, deviceCommandArgs } from "./remoteRunArgs";
import { firstLine, signingGuidance, stderrDetailLine, withSourceContext } from "./monitorDeviceOpsText";
import {
  MonitorDeviceCreateOps,
  type BatchCreateDevicesMessage,
  type CreateDeviceMessage,
  type DevicePickDeviceDeleteMessage,
} from "./monitorDeviceCreateOps";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts の FleetestProcess と同じ形)。 */
type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

/** プロファイルタブの「Wipe Data」1台分(runProfileDeviceWipe メッセージの要素と同じ形)。
 * **identifier が主**(iOS = UDID / Android = AVD id)で、name は確認・ログ・タイル表示用。 */
type WipeTargetDevice = Extract<MonitorFromWebviewMessage, { type: "runProfileDeviceWipe" }>["devices"][number];

/** 「GPU で再起動」の1台ぶん(deviceRestartGpu / devicesRestartGpu の要素と同じ形)。
 * machine 省略 = 手元。 */
type GpuRestartTarget = Extract<MonitorFromWebviewMessage, { type: "devicesRestartGpu" }>["devices"][number];

/** デバイスライフサイクルの直列キューおよび device-catalog/installed-devices/create-device の
 * 短命プロセス実行を担う。MonitorPanelController が1つ保持する。 */
export class MonitorDeviceOps {
  /**
   * デバイスライフサイクル操作のスケジューラ。device ジョブは最大2台まで同時実行
   * (右クリック起動の2台並行=一括起動の2台固定ポリシーと同じ上限)、bulk/restartBatch は
   * 単独占有(内部で2台並行するため)。**device ジョブを並行にしてよいのは ProvisionLock
   * (クロスプロセス flock)が供給を直列化しているから** —— 供給が並行に走ると waitUntilReady
   * 失敗・ゾンビブリッジを誘発する。状態遷移(queued/running)の純粋ロジックは
   * monitorModel.ts 側(vscode 非依存・単体テスト対象)。
   */
  private lifecycleQueue: DeviceLifecycleQueueState = createDeviceLifecycleQueueState();
  /** 実機の起動で人の操作(ロック解除・UI 自動化の承認)を促す通知。タイルの文言だけでは気付かれない */
  private readonly deviceActionNotices = new DeviceActionNotices(
    (line) => this.deps.outputChannel.appendLine(line));
  /** デバイスの新規作成/削除(create-device・delete-device・install-system-image)の実処理。
   * 状態(多重実行ガード)は書き込み箇所と同じこのサブコントローラの中に閉じる。 */
  private readonly createOps: MonitorDeviceCreateOps;
  /** 実行中の bulk up(start-all-devices)プロセス。「デバイスの起動を中断」の kill 対象。close で undefined に戻す。 */
  private bulkUpProc: PipeProcess | undefined;
  /** 実行中の device up ジョブのプロセスと取り消しの印(cancelDeviceUp)。**鍵はジョブ**(再試行を跨いで同一) */
  private readonly deviceUpRuns = new Map<DeviceLifecycleJob, { proc?: PipeProcess; cancelled: boolean }>();
  /** 凍結が治らず CPU 描画(swiftshader)へフォールバックしたデバイス論理名。セッション中維持
   * (host に戻すと再凍結するため)。個別 start-device 時に --gpu を、bulk start-all-devices
   * (executeBulkJob)時に --cpu-render を付ける(CLI 側の同期相手:
   * Sources/fleetest/ApiDeviceCommands.swift の cpuRender → DeviceBooter.bootAll)。 */
  private readonly cpuRenderNames = new Set<string>();

  constructor(private readonly deps: MonitorPanelDeps) {
    this.createOps = new MonitorDeviceCreateOps(this.deps);
  }

  /** ライフサイクルキューに実行中/待機中のジョブがあるか。watchdog が「一括down 実行中に
   * 無応答と誤検知して停止デバイスを再起動する」競合を避けるため、修復 up の抑止判定に使う。 */
  isQueueBusy(): boolean {
    return isDeviceLifecycleQueueBusy(this.lifecycleQueue);
  }

  /** キューが空になったら解決する待ち手(「テストを実行」の起動待ち。monitorPanel)。 */
  private queueIdleWaiters: (() => void)[] = [];

  /** ライフサイクルキューが空になるまで待つ(既に空なら即解決)。「テストを実行」が
   * 一括起動の完了を待ってから run を投げるための口 —— 中断で bulk up を止めた場合も
   * ジョブが終わって空になるので同じように解決する(呼び手が中断を見て run を諦める)。 */
  whenLifecycleQueueIdle(): Promise<void> {
    if (!this.isQueueBusy()) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      this.queueIdleWaiters.push(resolve);
    });
  }

  private resolveQueueIdleWaiters(): void {
    if (this.isQueueBusy() || this.queueIdleWaiters.length === 0) {
      return;
    }
    const waiters = this.queueIdleWaiters;
    this.queueIdleWaiters = [];
    for (const resolve of waiters) {
      resolve();
    }
  }

  /**
   * デバイスライフサイクル操作をキューに積む。空なら即実行、そうでなければ先行ジョブの完了後に
   * 実行される。同じデバイスへの deviceOp が既にキュー内(実行中/待機中)にあれば連打とみなして
   * 無視する(webview 側は `isDeviceLifecycleQueueBusy` でボタンを disabled にするため、通常は
   * ここに届く前に抑止される)。
   */
  enqueueLifecycleJob(job: DeviceLifecycleJob): void {
    if (job.kind === "device" && hasDeviceLifecycleJobFor(this.lifecycleQueue, job.name, job.machine)) {
      return;
    }
    this.pushLifecycleJob(job);
  }

  /**
   * プロファイルタブのデバイス行右クリック「Wipe Data」。**不可逆なのでホスト側 modal で必ず確認する**
   * (webview の window.confirm は効かない。runDeleteDevice と同じ方式)。確認後は enqueueWipe で
   * 直列キューへ積む。
   */
  async runWipeDevices(devices: readonly WipeTargetDevice[]): Promise<void> {
    if (devices.length === 0) {
      return;
    }
    const wipeLabel = t("deviceOps.wipeConfirmButton");
    const choice = await vscode.window.showWarningMessage(
      t("deviceOps.wipeConfirmMessage"),
      { modal: true, detail: t("deviceOps.wipeConfirmDetail") },
      wipeLabel,
    );
    if (choice !== wipeLabel) {
      return;
    }
    const queued = this.enqueueWipe(devices);
    if (queued === 0) {
      void vscode.window.showWarningMessage(`fleetest: ${t("deviceOps.wipeAllBusy")}`);
      return;
    }
    // **受け付けたことをその場で返す**(実行はキュー越しで、しかも数分かかる)。進行そのものは
    // 「デバイスモニター」タブのタイルが出す(停止中 → 再起動中)ので、ここでは行き先だけ案内する。
    // modal = 確認ダイアログと同じ場所に出す(通知だと右下に一瞬出て見落とす。ユーザー決定)
    void vscode.window.showInformationMessage(t("deviceOps.wipeStarted"), { modal: true });
  }

  /** プロファイルタブのデバイス行右クリック「Wipe Data」: 対象を1台ずつ device ジョブとして積む
   * (実処理は `fleetest api wipe-device`)。**確認は runWipeDevices で済ませてから呼ぶ**
   * (この関数自体は聞かない)。既に同じ台のジョブがキューに居れば無視する
   * (引き当ては (machine, name) —— 別の機械の同名の台は別の台)。
   * 積めた台数を返す(0 = 全部が既に処理中)。 */
  enqueueWipe(devices: readonly WipeTargetDevice[]): number {
    let queued = 0;
    for (const device of devices) {
      if (hasDeviceLifecycleJobFor(this.lifecycleQueue, device.name, device.machine)) {
        this.deps.outputChannel.appendLine(t("deviceOps.log.wipeSkippedBusy", { name: device.name }));
        continue;
      }
      this.pushLifecycleJob({
        kind: "device", name: device.name, op: "wipe", machine: device.machine,
        platform: device.platform, identifier: device.identifier,
      });
      queued += 1;
    }
    return queued;
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

  /** MonitorHealthWatchdogDeps.forceCpuRender への実装。以後この名前の start-device は
   * swiftshader で起動する(セッション中維持)。 */
  markCpuRender(name: string): void {
    this.cpuRenderNames.add(name);
  }

  /** monitorDevices 観測ごとに呼ぶ。CPU 描画でなくなった個体を記憶から落とす。
   * 実行プロファイルの recoverCpuFallbackToGpu(run 開始時の GPU 復帰。Swift 側
   * AndroidGpuRecovery)は拡張の外で emulator を入れ替えるため、これが無いと記憶だけ CPU のまま
   * 残り、次の個別 start-device がタイルのバッジと矛盾して再び swiftshader で起こしてしまう。
   * **ライフサイクルジョブ進行中の個体は対象外**: watchdog の CPU フォールバックは
   * markCpuRender → enqueueRestart の順で、再起動が始まるまでの数秒はまだ GPU で connected の
   * ままなので、除外しないと記憶が使われる前に消える(=フォールバックが永久に発動しない)。 */
  syncCpuRenderNames(devices: readonly MonitorDevice[]): void {
    for (const device of devices) {
      if (device.platform !== "android" || device.state !== "connected") {
        continue;
      }
      // 名簿は手元の watchdog のもの(name 単位)。リモートの同名の台が GPU で connected でも
      // 手元の記憶を落とさない
      if (device.machine !== undefined) {
        continue;
      }
      if (device.renderMode === undefined || device.renderMode === "cpu") {
        continue;
      }
      if (hasDeviceLifecycleJobFor(this.lifecycleQueue, device.name)) {
        continue;
      }
      this.cpuRenderNames.delete(device.name);
    }
  }

  /** 「GPUで再起動」(手動・右クリックメニュー): 単発もバッチ(1件)として実行する。 */
  restartWithGpu(name: string, machine?: string): void {
    this.restartWithGpuBatch([{ name, machine }]);
  }

  /** 「デバイスを全て起動」: 未起動機のブートと CPU バッジ機の GPU 再起動を1ジョブ
   * (start-all-devices --restart)に統合して積む。CLI 側の単一キューを2ワーカーが消化するため、
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
  /** タイルの「起動をキャンセル」: 1台の起動を止めて未起動へ戻す。待機中ならキューから外すだけ。
   * 実行中なら再試行を止めて start-device を SIGTERM し、終わったら同じ台の停止ジョブを積む ——
   * エミュレータ/simctl の起動は detach 済みで、プロセスを止めても台は起動しきってしまうため。 */
  cancelDeviceUp(name: string, machine?: string): void {
    const queued = removeQueuedDeviceUpJob(this.lifecycleQueue, name, machine);
    if (queued.removed) {
      this.lifecycleQueue = queued.state;
      this.deps.outputChannel.appendLine(t("deviceOps.log.deviceUpCancelledQueued", { name }));
      this.postDeviceLifecycleStatus(name, machine);
      this.postBootBusy();
      return;
    }
    const running = this.lifecycleQueue.running.find(
      (job) => job.kind === "device" && job.op === "up" && job.name === name && job.machine === machine);
    const upRun = running ? this.deviceUpRuns.get(running) : undefined;
    if (!upRun || upRun.cancelled) {
      return;
    }
    upRun.cancelled = true;
    this.deps.outputChannel.appendLine(t("deviceOps.log.deviceUpCancelling", { name }));
    // proc が無い = 再試行の待ち中。次の試行の入口で打ち切る(runDeviceOpAttempt)
    upRun.proc?.kill("SIGTERM");
  }

  cancelBulkUp(): void {
    const runningBulkUp = this.lifecycleQueue.running.some(
      (job) => job.kind === "bulk" && job.op === "up",
    );
    if (runningBulkUp) {
      if (this.bulkUpProc) {
        this.deps.outputChannel.appendLine(t("deviceOps.log.cancelBulkUpSigterm"));
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
      this.deps.outputChannel.appendLine(t("deviceOps.log.bulkUpQueueCancelled"));
    }
  }

  /** CPU 描画フォールバックの記憶を解除し、手元の台は restart-devices(2台ずつ並行の down→up)
   * 1ジョブでまとめて再起動する。次回起動は --gpu が付かず host(GPU)。以後また画面凍結して
   * watchdog の自動フォールバックが走れば CPU に戻る(既知のトレードオフ。docs/design.md §12.4)。
   * **別の機械の台はその機械で down→up する**(タイルの起動/停止と同じ device ジョブ =
   * `remote exec <machine> -- api stop-device/start-device … --device-machine local`)。
   * `restart-devices` は手元専用(ApiDevicesRestart の foreign: .notHandled)で、名前だけで
   * 積むとリモートのタイルの「GPU で再起動」が**手元の同名の台**を再起動する。
   * 直列キューに既に載っているデバイスは除外(連打防止の既存方針)。 */
  restartWithGpuBatch(targets: readonly GpuRestartTarget[]): void {
    const localNames: string[] = [];
    const remote: GpuRestartTarget[] = [];
    for (const target of targets) {
      if (hasDeviceLifecycleJobFor(this.lifecycleQueue, target.name, target.machine)) {
        continue;
      }
      if (target.machine === undefined) {
        this.cpuRenderNames.delete(target.name);
        localNames.push(target.name);
      } else {
        remote.push(target);
      }
    }
    if (localNames.length > 0) {
      this.pushLifecycleJob({ kind: "restartBatch", names: localNames });
    }
    for (const { name, machine } of remote) {
      // down→up の逐次性は promoteDeviceLifecycleJobs が (machine, name) で守る(enqueueRestart と同型)
      this.pushLifecycleJob({ kind: "device", name, op: "down", machine });
      this.pushLifecycleJob({ kind: "device", name, op: "up", machine });
    }
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
      this.postDeviceLifecycleStatus(job.name, job.machine);
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
  private postDeviceLifecycleStatus(name: string, machine?: string): void {
    const status = deviceLifecycleStatusFor(this.lifecycleQueue, name, machine);
    // **machine も載せる** —— 載せないと webview が同名の先頭のタイル(= 手元)を書き換え、
    // 「M2Ultra の台を停止」が手元のタイルに「シャットダウン中」と出る(2026-08-17 の実害)
    // op:"up" を返すのは device ジョブだけ(bulk / restartBatch は down の順番待ちで返る)= 取り消せる
    this.deps.post({
      type: "deviceOpBusy", name, machine, op: status?.op ?? null, status: status?.status ?? null,
      cancellable: status?.op === "up",
    });
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

  /** キュー先頭のジョブを実行する(devices up/down の一括実行、または start-device/stop-device の個別実行)。 */
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
      this.postDeviceLifecycleStatus(job.name, job.machine);
      // wipe も中で必ず止めるので、down と同じくストリームを先に畳む(残すと消えた台の
      // 最終フレームが stall 自己修復まで固まって見える)。
      if (job.op === "down" || job.op === "wipe") {
        this.deps.stopDeviceStreams(job.name, job.machine);
      }
      this.executeDeviceOpJob(job);
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
      // **host も載せる**(表示の剥がしも宛先を間違えない。postDeviceLifecycleStatus と同じ理由)
      this.deps.post({
        type: "deviceOpBusy", name: finished.name, machine: finished.machine, op: null, status: null,
      });
      // wipe は失敗・異常終了だと "done" が来ないまま終わりうるので、ここでも Wipe 表示を剥がす
      // (failed は残したい情報だが、ジョブが消えた後も残ると次の操作の判断を誤らせる)。
      if (finished.op === "wipe") {
        this.deps.post({ type: "wipeStatus", name: finished.name, machine: finished.machine, phase: "done" });
      }
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
    // **スケジューラを回した後に見る** —— 待機ジョブが昇格していれば空ではない
    this.resolveQueueIdleWaiters();
  }

  /**
   * `fleetest devices up`/`devices down` を短命プロセスとして実行する(bulk ジョブの実処理)。
   * 選択中の実行プロファイル(fleetest.profile)が非空なら --profile を付与し、対象を
   * そのプロファイルが参照するデバイスのみに限定する(空なら全実行プロファイルの和集合。
   * down も同様に --project/--profile を渡せる)。
   */
  private executeBulkJob(kind: "up" | "down", restartNames: readonly string[] = []): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    // up は api start-all-devices(deviceStarting/deviceFinished の NDJSON でタイルを即時更新)。
    // down は profile 指定時のみ api stop-all-devices(deviceStopping/deviceFinished の NDJSON。1台落ちる
    // ごとにそのタイルを「未起動」へ倒す)。profile 無しは従来の devices down(全ブリッジ停止+
    // simctl shutdown all+全 qemu kill の全掃討。プレーンテキスト)。
    const useNdjson = kind === "up" || (kind === "down" && !!config.profile);
    const args: string[] = kind === "up"
      ? ["api", "start-all-devices"]
      : useNdjson
        ? ["api", "stop-all-devices"]
        : ["devices", "down"];
    if (kind === "up") {
      // 起動済みでも down→up する対象(CPU バッジ機の GPU 復帰)。未起動機のブートと同一キューで
      // 2台ずつ並行処理される(DeviceBooter.bootAll の restartNames)。
      for (const n of restartNames) {
        args.push("--restart", n);
      }
      // CPU 描画フォールバック中の個体は一括起動でも swiftshader を維持する(従来は bulk up が
      // host で起き上がり直してフォールバックが消える既知の穴だった)
      for (const n of this.cpuRenderNames) {
        args.push("--cpu-render", n);
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
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(t("deviceOps.log.devicesStartFailed", { kind, error: String(error) }));
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

    if (!useNdjson) {
      // profile 無しの down = 従来の devices down(全掃討・プレーンテキスト)。
      // **CLI が run-lease で断ったら通知で見せる**(押す前の門 bulkDownGate は monitor の観測に頼るので、
      // 観測の遅れ・一時停止中は CLI 側で初めて断られる。OUTPUT の1行だけだと「押しても何も起きない」)
      let refusal: string | undefined;
      let partial = "";
      proc.stdout.on("data", (chunk: Buffer) => {
        const lines = (partial + chunk.toString("utf8")).split("\n");
        partial = lines.pop() ?? "";
        for (const line of lines) {
          refusal = sweepRefusalDetail(line) ?? refusal;
        }
        appendLines("stdout", chunk);
      });
      proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

      proc.on("error", (error) => {
        this.deps.outputChannel.appendLine(
          t("deviceOps.log.devicesRuntimeError", { kind, error: error.message }),
        );
        finishOnce();
      });
      proc.on("close", (exitCode) => {
        this.deps.outputChannel.appendLine(
          t("deviceOps.log.devicesClosed", { kind, exitCode: String(exitCode) }),
        );
        refusal = sweepRefusalDetail(partial) ?? refusal;
        if (exitCode !== 0 && refusal !== undefined) {
          void vscode.window.showWarningMessage(t("deviceOps.bulkDownRefused", { detail: refusal }));
        }
        finishOnce();
      });
      return;
    }

    // ---- NDJSON 経路(up: start-all-devices / profile 指定 down: stop-all-devices)----
    // up は deviceStarting/deviceFinished、down は deviceStopping/deviceFinished を per-device に流す。
    // モニターの状態スキャン到達を待たず、up は「起動中」、down は1台落ちるごとに「未起動」へタイルを
    // 即時反映する。イベント形は共通(isDevicesUpEvent)。stderr は診断ログのみでプレーンテキスト。
    const label = kind === "up" ? "devices up" : "devices down";

    // このジョブのクロージャ内だけで有効な「操作を掴んだがまだ完了していないデバイス」集合。
    // close 時に残っていればクラッシュ・kill とみなし、deviceOpBusy(null) で表示を剥がす
    // (正常終了なら deviceFinished で空になっているはずなので no-op)。
    // **鍵は (machine, name)** —— 名前だけだと、リモートの台の deviceFinished が同名の手元の台を
    // 集合から消し、手元がクラッシュしたときに表示が剥がれずに残る
    const started = new Map<string, { readonly name: string; readonly machine?: string }>();
    const startedKey = (name: string, machine?: string): string => `${machine ?? ""}\t${name}`;
    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDevicesUpEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", { label, value: JSON.stringify(value) }),
          );
          return;
        }
        switch (value.kind) {
          case "log":
            this.deps.outputChannel.appendLine(`[${label}] ${value.message}`);
            break;
          case "deviceStopping":
            // down 開始(up では --restart 対象)。ストリームをこのデバイスだけ止め(simctl/adb に
            // 殺される前にタイルを切断表示へ倒す。他デバイスのライブ映像は残す)、「シャットダウン中」に。
            // **host も渡す** —— 同名が別の機械にも居ると、名前だけでは別タイルを触ってしまう
            started.set(startedKey(value.name, value.machine ?? undefined),
              { name: value.name, machine: value.machine ?? undefined });
            this.deps.stopDeviceStreams(value.name, value.machine ?? undefined);
            this.deps.post({ type: "deviceOpBusy", name: value.name, machine: value.machine ?? undefined, op: "down", status: "running" });
            break;
          case "deviceStarting":
            started.set(startedKey(value.name, value.machine ?? undefined),
              { name: value.name, machine: value.machine ?? undefined });
            this.deps.post({ type: "deviceOpBusy", name: value.name, machine: value.machine ?? undefined, op: "up", status: "running" });
            break;
          case "deviceAction":
            this.deps.post({ type: "deviceAction", name: value.name, machine: value.machine ?? undefined, action: value.action });
            this.deviceActionNotices.update(value.name, value.machine ?? undefined, value.action);
            break;
          case "deviceFinished":
            started.delete(startedKey(value.name, value.machine ?? undefined));
            if (kind === "down") {
              // down 中はモニター pause で state 更新が来ないため、この per-device 通知でそのタイルを
              // 即「未起動」へ倒す(offline を先行反映。opBusy もここで解除される)。
              this.deps.post({ type: "deviceDownFinished", name: value.name, machine: value.machine ?? undefined });
            } else {
              this.deps.post({ type: "deviceOpBusy", name: value.name, machine: value.machine ?? undefined, op: null, status: null });
            }
            break;
          case "machineFailed": {
            // その機械のぶんが丸ごと起きなかった。親の finished は ok:true で来るので、
            // ここでバナーに出さないと OUTPUT にしか残らず無音になる(1行目だけ = finished と同じ規律)
            const message = t("deviceOps.remoteMachineFailed", {
              machine: value.machine, error: firstLine(value.error),
            });
            this.deps.outputChannel.appendLine(`[${label}] ❌ [${value.machine}] ${value.error}`);
            this.deps.post({ type: "deviceError", message });
            break;
          }
          case "finished":
            if (!value.ok) {
              const detail = value.error ?? t("deviceOps.detailUnknown");
              this.deps.outputChannel.appendLine(t("deviceOps.log.bulkOpFailed", { label, error: detail }));
              // **バナーにも出す** —— ログだけだと「押したのに何も始まらない」にしか見えない
              // (実害 2026-08-29: プロファイル未選択で台帳を決められず即死していたのに無反応だった)。
              // 1行目だけ = 外から来た生のエラーは長くなりうる(deviceOpFailed と同じ規律)
              this.deps.post({ type: "deviceError", message: firstLine(detail) });
            }
            break;
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[${label} stdout] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => appendLines("stderr", chunk));

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.devicesRuntimeError", { kind, error: error.message }),
      );
      finishOnce();
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      // クラッシュ・kill でタイルの「起動中」表示が永久に残らないためのクリーンアップ
      // (正常終了なら deviceFinished 済みでこの Set は空 = 無害な no-op)。
      for (const { name, machine } of started.values()) {
        this.deps.post({ type: "deviceOpBusy", name, machine, op: null, status: null });
        this.deviceActionNotices.release(name, machine);
      }
      started.clear();
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.devicesClosed", { kind, exitCode: String(exitCode) }),
      );
      finishOnce();
    });
  }

  /**
   * `fleetest api restart-devices` を短命プロセスとして実行する(restartBatch ジョブの実処理)。
   * CLI 側が 2 台ずつ並行で down→up し、per-device の deviceStopping/deviceStarting/deviceFinished
   * NDJSON を流す(契約: monitorModel.ts isDevicesRestartEvent / Sources/fleetest/ApiDeviceCommands.swift)。
   * 全体の構造(spawn 例外・'error'+'close' 二重発火の finishOnce ガード・close 時の表示剥がし)は
   * executeBulkJob の up 経路と同じ。
   */
  private executeRestartBatchJob(names: readonly string[]): void {
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    const args: string[] = ["api", "restart-devices"];
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
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.devicesRestartStartFailed", { error: String(error) }),
      );
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
            t("deviceOps.log.unknownLine", { label: "restart-devices", value: JSON.stringify(value) }),
          );
          return;
        }
        switch (value.kind) {
          case "log":
            this.deps.outputChannel.appendLine(`[restart-devices] ${value.message}`);
            break;
          case "deviceStopping":
            // このデバイスの down が始まる。ストリームをここで止める(simctl/adb に殺される前に
            // タイルを切断表示へ倒す。バッチ開始時に全台止めない理由は runLifecycleQueueHead 参照)。
            busyNames.add(value.name);
            // restart-devices(GPU 復帰)は手元の Android エミュレータ専用なので host を持たない
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
                t("deviceOps.log.devicesRestartFailed", { error: value.error ?? t("deviceOps.detailUnknown") }),
              );
            }
            break;
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[restart-devices stdout] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          this.deps.outputChannel.appendLine(`[restart-devices stderr] ${line}`);
        }
      }
    });

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.devicesRestartRuntimeError", { error: error.message }),
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
        t("deviceOps.log.devicesRestartClosed", { exitCode: String(exitCode) }),
      );
      finishOnce();
    });
  }

  /** device ジョブの op から、実際に叩く CLI サブコマンド名(ログ・失敗メッセージの表示用)。 */
  private static deviceOpCommandName(op: "up" | "down" | "wipe"): string {
    switch (op) {
      case "up": return "start-device";
      case "down": return "stop-device";
      case "wipe": return "wipe-device";
    }
  }

  /** up が失敗したときの追加試行回数(計 1+2=3 回)。再起動(down→up)の up が転けてデバイスが
   * 下がったまま放置される事故を防ぐ。watchdog は offline/消失を blank-screen として拾えず
   * 二度と復旧しないため、この経路で確実に復帰を試みる。down は再試行しない(消したいだけなので)。 */
  private static readonly deviceUpMaxRetries = 2;
  /** up 再試行の間隔(ミリ秒)。直前の失敗した起動/adb を落ち着かせてから再スポーンする。 */
  private static readonly deviceUpRetryDelayMs = 3000;

  /**
   * タイル右クリックメニューの起動/停止項目・再起動(down→up)から、デバイス1台だけを
   * `fleetest api start-device`/`stop-device` で起動/停止する(device ジョブの実処理)。
   * up が失敗した場合は deviceUpMaxRetries まで再試行してからキューを進める。
   * 失敗時(finished ok:false、または finished を出せずに落ちた場合を含む)は、バナーがパネルを
   * 閉じると消えるため、事後診断できるよう出力チャネルにも必ずログを残す。
   */
  private executeDeviceOpJob(job: Extract<DeviceLifecycleJob, { kind: "device" }>): void {
    // spawn 失敗時の 'error'+'close' 二重発火・複数試行にまたがる finish の二重呼び出しを防ぐ
    // ジョブ単位のガード(finishLifecycleQueueHead は1ジョブにつき1回だけ呼ぶ)。
    let jobFinished = false;
    const upRun = job.op === "up" ? { cancelled: false } : undefined;
    if (upRun) {
      this.deviceUpRuns.set(job, upRun);
    }
    const finishOnce = (): void => {
      if (jobFinished) {
        return;
      }
      jobFinished = true;
      this.deviceUpRuns.delete(job);
      // **machine も入れる** —— sameLifecycleJob は (machine, name, op) で照合するので、
      // 落とすと「実行中に該当ジョブがありません」になる
      this.finishLifecycleJob(job);
      if (upRun?.cancelled && job.op === "up") {
        // 取り消した起動は未起動へ戻す(起動は detach 済みで止まらない)。識別子は up と同じもので撃つ
        this.enqueueLifecycleJob({
          kind: "device", name: job.name, op: "down", machine: job.machine, udid: job.udid, serial: job.serial,
        });
      }
    };
    this.runDeviceOpAttempt(job, 0, finishOnce);
  }

  /** start-device/stop-device の1回分の実行。up が失敗し追加試行が残っていれば遅延後に再試行、
   * それ以外(成功・down・up の上限到達)は finishOnce でキューを進める。 */
  private runDeviceOpAttempt(
    job: Extract<DeviceLifecycleJob, { kind: "device" }>,
    attempt: number,
    finishOnce: () => void,
  ): void {
    const { name, op, machine } = job;
    const upRun = this.deviceUpRuns.get(job);
    if (upRun?.cancelled) {
      finishOnce();
      return;
    }
    const udid = job.op === "wipe" ? undefined : job.udid;
    const serial = job.op === "wipe" ? undefined : job.serial;
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    // 未登録(どの実行プロファイルにも記載の無い)デバイスの直指定モード: --name の代わりに
    // --udid/--serial を渡し、プロジェクト解決に使う --project/--profile も付けない(直指定はそれらを
    // 一切参照しない契約。Sources/fleetest/ApiDeviceCommands.swift ApiDeviceDownDirectTarget)。
    // **up の直指定は --udid だけ** —— 実機のブリッジ起動(start-device --udid)がそれ。
    // serial(Android)の up は端末の電源を入れる操作になり存在しないので down のみ。
    const direct = udid !== undefined || (op === "down" && serial !== undefined);
    // **別の機械の台はその機械で操作する** —— 手元で `--name` を渡すと、手元の実行
    // プロファイルの同名エントリを引いて**別の機械の設定でこの Mac にシミュレータを作る**
    // (simctl は無ければ作る)。一括起動が RemoteDeviceFanout で分散するのと同じ規律
    const args: string[] = machine ? ["remote", "exec", machine, "--"] : [];
    args.push("api", op === "up" ? "start-device" : op === "down" ? "stop-device" : "wipe-device");
    // **wipe は識別子だけで撃つ**(delete-device と同じ契約: プロジェクトも実行プロファイルも
    // 参照しない)。名前で引く形にすると、リモートでは向こうのプロファイル複製が古いと
    // `device not found` で必ず失敗し、操作のたびにプロジェクトを送り直す羽目になる
    // (複製が更新されるのはモニターの fan-out 開始時だけ。2026-08-29 に実機で確認)
    if (job.op === "wipe") {
      args.push("--platform", job.platform,
                job.platform === "ios" ? "--udid" : "--avd", job.identifier);
    } else if (direct) {
      if (udid !== undefined) {
        args.push("--udid", udid);
      } else if (serial !== undefined) {
        args.push("--serial", serial);
      }
    } else {
      args.push("--name", name);
      if (resolution.kind === "resolved") {
        args.push("--project", resolution.project);
      }
      // machine 解決に使う。実行プロファイルの machine 指定を determineMachine が最優先で採用するため、
      // これが無いと machines/ が複数のとき「マシン名が未登録」で落ちてブリッジ供給に到達しない
      // (executeBulkJob と同経路。ApiDeviceUp/Down 側の --profile と対)。
      if (config.profile) {
        args.push("--profile", config.profile);
      }
      // **常に "local"**(リモートでも)。宛先はもう `remote exec <machine>` で選んでおり、
      // 向こうへ送ったプロファイルは**自分の台を machine:"local" に畳んである**
      // (FTCore.RunnerProfileView。転送物にも引数にもエイリアスは出ない = CLAUDE.md の規律)。
      // エイリアスを渡すと向こうで一致するエントリが無く
      // `device not found: <名前> on <machine>` になる(fan-out の子・device-stream も local で走る)。
      // 手元でも渡す = 同名のリモート機の台を引かないための絞り込み
      args.push("--device-machine", "local");
    }
    // 名簿は手元の watchdog のもの(name 単位)。別の機械の同名の台に付けると、向こうを
    // 理由なく CPU 描画で起こす(= リモートの「GPU で再起動」が GPU で上がらない)
    if (op === "up" && machine === undefined && this.cpuRenderNames.has(name)) {
      args.push("--gpu", "swiftshader_indirect");
    }

    const attemptLabel = attempt > 0
      ? t("deviceOps.retryLabel", { attempt, max: MonitorDeviceOps.deviceUpMaxRetries })
      : "";
    let failureLogged = false;
    const logFailure = (message: string): void => {
      failureLogged = true;
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.deviceOpFailed", { command: MonitorDeviceOps.deviceOpCommandName(op), name, attemptLabel, message }),
      );
    };

    // 署名エラー(finished の signingProblems 付き)は設定の問題で、再試行しても必ず同じ失敗に
    // なる。リトライすると同じバナーが試行のたびに出て、実機のフルビルドも余計に払う
    let signingFailure = false;
    // この試行の終端('error' と 'close' の二重発火を1回に集約)。up が失敗し追加試行が残っていれば
    // 再試行(キューは進めない)、それ以外は finishOnce。
    let attemptSettled = false;
    const settle = (failed: boolean): void => {
      if (attemptSettled) {
        return;
      }
      attemptSettled = true;
      if (upRun?.cancelled) {
        finishOnce();
        return;
      }
      if (failed && !signingFailure && op === "up" && attempt < MonitorDeviceOps.deviceUpMaxRetries) {
        this.deps.outputChannel.appendLine(
          t("deviceOps.log.deviceUpRetrying", {
            name,
            nextAttempt: attempt + 1,
            max: MonitorDeviceOps.deviceUpMaxRetries,
            delayMs: MonitorDeviceOps.deviceUpRetryDelayMs,
          }),
        );
        setTimeout(
          // **machine を落とさない** —— 落とすと再試行だけ手元で走り、別の機械の台に対して
          // 「そんな UDID の実機は無い(認識しているのは…)」という**見当違いのエラー**が
          // 最後に出て、本当の失敗理由(向こうの署名エラー等)が隠れる(実害 2026-08-29)
          () => this.runDeviceOpAttempt(job, attempt + 1, finishOnce),
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
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      logFailure(String(error));
      this.deps.post({ type: "deviceOpFailed", name, machine, message: String(error) });
      settle(true);
      return;
    }
    if (upRun) {
      upRun.proc = proc;
    }

    const stdoutParser = new NdjsonParser(
      (value) => {
        if (!isDeviceOpEvent(value)) {
          this.deps.outputChannel.appendLine(
            t("deviceOps.log.unknownLine", {
              label: `${MonitorDeviceOps.deviceOpCommandName(op)} ${name}`,
              value: JSON.stringify(value),
            }),
          );
          return;
        }
        if (value.kind === "log") {
          this.deps.outputChannel.appendLine(`[${MonitorDeviceOps.deviceOpCommandName(op)} ${name}] ${value.message}`);
        } else if (value.kind === "deviceAction") {
          // タイルは起動を頼んだ名前で引く(--udid 直指定では CLI 側の名前が端末名になりうる)
          this.deps.post({ type: "deviceAction", name, machine, action: value.action });
          this.deviceActionNotices.update(name, machine, value.action);
        } else if (value.kind === "wipeStatus") {
          // run 開始時の自動 Wipe と同じタイル表示を使う(footer の「Wipe: 停止中/再起動中」)。
          // **machine も載せる** —— 名前だけだと同名の手元タイルが書き換わる
          this.deps.post({ type: "wipeStatus", name, machine, phase: value.phase });
        } else if (!value.ok && upRun?.cancelled) {
          // 取り消しで止めた結果の失敗は失敗として出さない
          failureLogged = true;
        } else if (!value.ok) {
          signingFailure = value.signingProblems !== undefined;
          // 署名の欠けは**こちらの言語で**組み立て直す(CLI の error は英語 = CLI 利用者向け)
          // 別の機械へ投げた(remote exec = ssh)ならポータル通信ができない旨を添える
          const localized = value.signingProblems === undefined
            ? null
            : signingGuidance(value.signingProblems, value.signingLogPath, machine !== undefined);
          const message = localized ?? value.error
            ?? t("deviceOps.deviceOpFailedGeneric", { command: MonitorDeviceOps.deviceOpCommandName(op) });
          logFailure(message);
          // **自分で組み立てた案内は全文をバナーへ**(短く整形済みで数行。読み切れる)。
          // signingProblems 付きの error も全文 —— CLI が畳んだ数行の案内で、生のビルドログ
          // ではない(こちらで組み立てられない種別のときの受け皿)。
          // 外から来た生のエラーは1行目だけ —— xcodebuild のビルドログのように数十行あり得て、
          // 全文を流すとパネルが埋まる(実害 2026-08-29)。
          // **OUTPUT へは誘導しない** —— 常時流れていて利用者が読む場所ではない(ユーザー決定)
          this.deps.post({
            type: "deviceOpFailed", name, machine,
            message: localized ?? (value.signingProblems !== undefined ? message : firstLine(message)),
          });
        }
      },
      (line) => this.deps.outputChannel.appendLine(`[${MonitorDeviceOps.deviceOpCommandName(op)} ${name} stdout] ${line}`),
    );
    // **stderr を控える** —— CLI が NDJSON を出さずに終わる失敗(引数・プロファイル解決の
    // ValidationError 等)は理由が stderr にしか無い。控えないと close の分岐で
    // 「exit code だけ」になり、**バナーに何も出ないまま失敗する**(実害 2026-08-29:
    // タイルの「ブリッジ起動」が無反応に見えた)
    let stderr = "";
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[${MonitorDeviceOps.deviceOpCommandName(op)} ${name} stderr] ${JSON.stringify(value)}`),
      (line) => {
        stderr += `${line}\n`;
        this.deps.outputChannel.appendLine(`[${MonitorDeviceOps.deviceOpCommandName(op)} ${name} stderr] ${line}`);
      },
    );

    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderrParser.push(chunk));

    proc.on("error", (error) => {
      logFailure(error.message);
      this.deps.post({ type: "deviceOpFailed", name, machine, message: error.message });
      settle(true);
    });
    proc.on("close", (exitCode) => {
      stdoutParser.end();
      stderrParser.end();
      // action:null を出さずに終わった(クラッシュ・kill・取り消し)ときに通知を残さない
      this.deviceActionNotices.release(name, machine);
      this.deps.outputChannel.appendLine(
        t("deviceOps.log.deviceOpClosed", {
          command: MonitorDeviceOps.deviceOpCommandName(op), name, attemptLabel, exitCode: String(exitCode),
        }),
      );
      // finished(ok:false)を経由せずに落ちたケース(引数エラー・クラッシュ・kill 等)を捕捉する。
      // finished 経由で既にログ済みの場合は二重に出さない。
      // **バナーにも出す** —— ログだけだと利用者からは無反応に見える。理由は stderr の
      // 最後の実質行(CLI はそこに原因を書く。stderrDetailLine の doc 参照)
      if (!failureLogged && exitCode !== 0 && !upRun?.cancelled) {
        const detail = stderrDetailLine(stderr);
        // **exit 64 = 引数エラー**(ArgumentParser)。リモートで出たなら、ほぼ「向こうの fleetest が
        // 古くてこのサブコマンド/オプションを知らない」(spawnCreateDevice と同じ読み替え)
        const message = exitCode === 64 && machine !== undefined
          ? t("deviceOps.remoteCliTooOld", { machine, detail: detail ?? "" })
          : detail === null
            ? t("deviceOps.processExitedWithCode", { exitCode: String(exitCode) })
            : detail;
        logFailure(message);
        this.deps.post({ type: "deviceOpFailed", name, machine, message });
      }
      settle(failureLogged);
    });
  }

  // ---- プロファイルタブ: デバイスカタログ取得 -----------------
  // いずれもデバイスライフサイクルの直列キュー(lifecycleQueue)には載せない —
  // 単なる参照系の単発コマンドで、simctl/adb 起動系のキューと競合する処理ではないため。
  // デバイス追加(create-device)はモーダル側の1件実行ガードで足り、MonitorDeviceCreateOps に居る。

  /**
   * `fleetest api device-catalog` を短命プロセスとして実行し、結果を webview へ返す。
   * 多重リクエストはボタン側(モーダルは開いた直後に1回だけ送る)で抑止する前提のため、
   * ここでは単純に都度実行する。stdout を全量蓄積し、close 時にまとめて JSON.parse する
   * (単発 JSON 1行の出力なので NDJSON パーサは不要)。
   * source が remote なら deviceCommandArgs が `remote exec <host> -- api device-catalog` に
   * 組み立てる(§13 段2。個別 ssh 実装は書かない)。local は従来どおり `api device-catalog` のまま
   * (deviceCommandArgs の local 分岐が apiArgs を素通しするため、挙動は1バイトも変わらない)。
   */
  runDeviceCatalog(source: DeviceCommandSource): void {
    const config = this.deps.getConfig();
    const args = deviceCommandArgs(source, ["api", "device-catalog"]);

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = withSourceContext(
        t("deviceOps.cmdStartFailed", { cmd: "device-catalog", error: String(error) }),
        source,
      );
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
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
      const message = withSourceContext(
        t("deviceOps.cmdRuntimeError", { cmd: "device-catalog", error: error.message }),
        source,
      );
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
      flushStderr();
      respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const detail = stderrDetailLine(stderr);
        const message = withSourceContext(
          detail === null
            ? t("deviceOps.cmdFailedExitCode", { cmd: "device-catalog", exitCode: String(exitCode) })
            : t("deviceOps.cmdFailedExitCodeDetail", { cmd: "device-catalog", exitCode: String(exitCode), detail }),
          source,
        );
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = withSourceContext(
          t("deviceOps.cmdParseFailed", { cmd: "device-catalog", error: String(error) }),
          source,
        );
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      if (!isDeviceCatalogJson(parsed)) {
        const message = withSourceContext(t("deviceOps.cmdOutputInvalid", { cmd: "device-catalog" }), source);
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "deviceCatalog", ok: false, catalog: null, error: message });
        return;
      }
      respond({ type: "deviceCatalog", ok: true, catalog: parsed, error: null });
    });
  }

  /**
   * `fleetest api install-cmdline-tools` を実行して Android SDK Command-line Tools を導入する。
   * 148MB のダウンロードを伴い数分かかるため、進捗(CLI の stderr)は貯めずに行単位で OUTPUT へ流す。
   * 結果は stdout 末尾の単発 JSON。多重実行は webview 側のボタン無効化で抑止する。
   */
  runInstallCmdlineTools(): void {
    const config = this.deps.getConfig();
    const cmd = "install-cmdline-tools";

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, ["api", cmd], {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = t("deviceOps.cmdStartFailed", { cmd, error: String(error) });
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
      this.deps.post({ type: "installCmdlineToolsResult", ok: false, error: message });
      return;
    }

    let stdout = "";
    let stderrTail = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    // 行が途中で切れて届くので、改行までバッファしてから1行ずつ出す
    proc.stderr.on("data", (chunk: Buffer) => {
      stderrTail += chunk.toString("utf8");
      const lines = stderrTail.split("\n");
      stderrTail = lines.pop() ?? "";
      for (const line of lines) {
        this.deps.outputChannel.appendLine(`[${cmd}] ${line}`);
      }
    });

    let responded = false;
    const respond = (ok: boolean, error: string | null): void => {
      if (responded) {
        return;
      }
      responded = true;
      if (stderrTail.trim().length > 0) {
        this.deps.outputChannel.appendLine(`[${cmd}] ${stderrTail.trim()}`);
        stderrTail = "";
      }
      this.deps.post({ type: "installCmdlineToolsResult", ok, error });
    };

    proc.on("error", (error) => {
      const message = t("deviceOps.cmdRuntimeError", { cmd, error: error.message });
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
      respond(false, message);
    });
    proc.on("close", (exitCode) => {
      // 失敗時も stdout に ok:false の JSON が出る(理由文はそちらが具体的)。読めた方を優先する
      let parsed: { ok?: unknown; error?: unknown } | null = null;
      try {
        parsed = JSON.parse(stdout.trim().split("\n").pop() ?? "") as { ok?: unknown; error?: unknown };
      } catch {
        parsed = null;
      }
      if (parsed !== null && typeof parsed === "object" && typeof parsed.ok === "boolean") {
        const error = typeof parsed.error === "string" ? parsed.error : null;
        if (!parsed.ok) {
          this.deps.outputChannel.appendLine(`[fleetest] ${cmd}: ${error ?? "failed"}`);
        }
        respond(parsed.ok, parsed.ok ? null : error);
        return;
      }
      const message = t("deviceOps.cmdFailedExitCode", { cmd, exitCode: String(exitCode) });
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
      respond(false, message);
    });
  }

  /**
   * `fleetest api installed-devices` を短命プロセスとして実行し、結果を webview へ返す
   * (「+既存から選択」モーダルが開いた直後の installedDevicesRequest への応答。runDeviceCatalog と
   * 全く同じ短命 spawn パターン — 単発 JSON 1行の出力を全量蓄積して close 時にまとめて
   * JSON.parse する。source の扱いも runDeviceCatalog と同じ)。
   */
  runInstalledDevices(source: DeviceCommandSource): void {
    const config = this.deps.getConfig();
    const args = deviceCommandArgs(source, ["api", "installed-devices"]);

    let proc: PipeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const message = withSourceContext(
        t("deviceOps.cmdStartFailed", { cmd: "installed-devices", error: String(error) }),
        source,
      );
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
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
      const message = withSourceContext(
        t("deviceOps.cmdRuntimeError", { cmd: "installed-devices", error: error.message }),
        source,
      );
      this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
      flushStderr();
      respond({ type: "installedDevices", ok: false, data: null, error: message });
    });
    proc.on("close", (exitCode) => {
      flushStderr();
      if (exitCode !== 0) {
        const detail = stderrDetailLine(stderr);
        const message = withSourceContext(
          detail === null
            ? t("deviceOps.cmdFailedExitCode", { cmd: "installed-devices", exitCode: String(exitCode) })
            : t("deviceOps.cmdFailedExitCodeDetail", { cmd: "installed-devices", exitCode: String(exitCode), detail }),
          source,
        );
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout);
      } catch (error) {
        const message = withSourceContext(
          t("deviceOps.cmdParseFailed", { cmd: "installed-devices", error: String(error) }),
          source,
        );
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      if (!isInstalledDevicesJson(parsed)) {
        const message = withSourceContext(t("deviceOps.cmdOutputInvalid", { cmd: "installed-devices" }), source);
        this.deps.outputChannel.appendLine(`[fleetest] ${message}`);
        respond({ type: "installedDevices", ok: false, data: null, error: message });
        return;
      }
      respond({ type: "installedDevices", ok: true, data: parsed, error: null });
    });
  }

  /** デバイス追加モーダルの OK。実処理は MonitorDeviceCreateOps(多重実行ガード込み)へ委譲する。 */
  runCreateDevice(msg: CreateDeviceMessage): void {
    this.createOps.runCreateDevice(msg);
  }

  /** 「デバイスを追加」左下の「バッチ作成」。実処理は MonitorDeviceCreateOps へ委譲する。 */
  async runBatchCreateDevices(msg: BatchCreateDevicesMessage): Promise<void> {
    return this.createOps.runBatchCreateDevices(msg);
  }

  /** #device-pick-overlay の行右クリック「削除」。実処理は MonitorDeviceCreateOps へ委譲する。 */
  async runDeleteDevice(msg: DevicePickDeviceDeleteMessage): Promise<void> {
    return this.createOps.runDeleteDevice(msg);
  }
}
