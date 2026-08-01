// monitorDeviceLifecycle.ts
// デバイス個別起動/停止(device-up/device-down)・一括起動/終了(devices-up/devices-down/
// devices-restart)の NDJSON イベント型と、それらを1件ずつ直列実行するキューの純粋な状態管理
// (spawn 自体は monitorPanel.ts 側)。vscode に依存しない(monitorPanel.ts と
// test/monitorModel.test.mjs の両方から使うため)。

import { t } from "./i18n";
import { isRecord, type MonitorDeviceState } from "./monitorDeviceModel";

// ---- デバイス個別起動/停止(ftester api device-up / device-down) ------------------------
// 契約(Sources/ftester/ApiDeviceCommands.swift): `ftester api device-up --name <論理名>
// [--project <p>]` / `ftester api device-down --name <論理名> [--project <p>]` の stdout NDJSON:
//   {"kind":"log","message":".."} × n → {"kind":"finished","ok":bool,"error":string|null}
// (ok:false のときは exit code 1。診断は stderr のみ)。

export type DeviceOpKind = "up" | "down";

export interface DeviceOpLogEvent {
  readonly kind: "log";
  readonly message: string;
}

export interface DeviceOpFinishedEvent {
  readonly kind: "finished";
  readonly ok: boolean;
  readonly error: string | null;
}

export type DeviceOpEvent = DeviceOpLogEvent | DeviceOpFinishedEvent;

/** value が DeviceOpEvent として扱ってよいか判定する(isMonitorEvent と同じ方針)。 */
export function isDeviceOpEvent(value: unknown): value is DeviceOpEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "finished":
      return typeof value.ok === "boolean" && (value.error === null || typeof value.error === "string");
    default:
      return false;
  }
}

/** `ftester api devices-up` の NDJSON 1行分のイベント。
 * 契約の同期相手: Sources/ftester/ApiDeviceCommands.swift ApiDevicesUp(deviceStarting/deviceFinished は
 * ブート開始/完了の即時通知で、モニターの状態スキャンを待たずタイルを「起動中」表示にするために使う。
 * deviceStopping は --restart 指定デバイスの down 開始通知)。 */
export type DevicesUpEvent =
  | { readonly kind: "log"; readonly message: string }
  | { readonly kind: "deviceStopping"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceStarting"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceFinished"; readonly name: string; readonly platform: string }
  | { readonly kind: "finished"; readonly ok: boolean; readonly error: string | null };

/** value が DevicesUpEvent として扱ってよいか判定する(isDeviceOpEvent と同じ方針)。 */
export function isDevicesUpEvent(value: unknown): value is DevicesUpEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "deviceStopping":
    case "deviceStarting":
    case "deviceFinished":
      return typeof value.name === "string" && typeof value.platform === "string";
    case "finished":
      return typeof value.ok === "boolean" && (value.error === null || typeof value.error === "string");
    default:
      return false;
  }
}

/** `ftester api devices-restart` の NDJSON 1行分のイベント。deviceStopping/deviceStarting/
 * deviceFinished はバッチ内の1台ごとの down→up 進行通知(モニターの状態スキャンを待たず
 * タイルを更新するために使う。deviceLifecycleStatusFor は restartBatch を常に queued 扱いにする
 * ため、running 表示はこのイベント由来の deviceOpBusy post が担う)。 */
export type DevicesRestartEvent =
  | { readonly kind: "log"; readonly message: string }
  | { readonly kind: "deviceStopping"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceStarting"; readonly name: string; readonly platform: string }
  | { readonly kind: "deviceFinished"; readonly name: string; readonly platform: string }
  | { readonly kind: "finished"; readonly ok: boolean; readonly error?: string | null };

/** value が DevicesRestartEvent として扱ってよいか判定する(isDevicesUpEvent と同じ方針)。 */
export function isDevicesRestartEvent(value: unknown): value is DevicesRestartEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "log":
      return typeof value.message === "string";
    case "deviceStopping":
    case "deviceStarting":
    case "deviceFinished":
      return typeof value.name === "string" && typeof value.platform === "string";
    case "finished":
      return (
        typeof value.ok === "boolean" &&
        (value.error === undefined || value.error === null || typeof value.error === "string")
      );
    default:
      return false;
  }
}

/** タイル右クリックメニューの唯一の項目の表示状態。op はクリック時に実行する操作(disabled:true の間はクリック不可)。 */
export interface DeviceOpMenuItem {
  readonly label: string;
  readonly op: DeviceOpKind;
  readonly disabled: boolean;
}

/** タイルで実行中/待機中の操作(deviceOpBusy メッセージ・DeviceLifecycleQueue の状態から作る)。 */
export interface DeviceOpBusyState {
  readonly op: DeviceOpKind;
  readonly status: DeviceOpQueueStatus;
}

/**
 * タイル右クリックメニュー項目を決める(monitorPanel.ts 本体・webview 複製で使用)。
 * MonitorDeviceState の全パターンをカバーするため戻り値は null にならない。
 */
export function deviceOpMenuItem(
  state: MonitorDeviceState,
  busy: DeviceOpBusyState | undefined,
): DeviceOpMenuItem {
  if (busy?.status === "queued") {
    return { label: t("monitor.deviceOp.labelQueued"), op: busy.op, disabled: true };
  }
  if (busy?.op === "up") {
    return { label: t("monitor.deviceOp.labelStarting"), op: "up", disabled: true };
  }
  if (busy?.op === "down") {
    return { label: t("monitor.deviceOp.labelStopping"), op: "down", disabled: true };
  }
  return state === "offline"
    ? { label: t("monitor.deviceOp.labelStart"), op: "up", disabled: false }
    : { label: t("monitor.deviceOp.labelStop"), op: "down", disabled: false };
}

// ---- デバイスライフサイクル操作の直列キュー ------------------------------------------------
// 「全て起動/終了」(bulk)とタイル個別操作(device)は、ブリッジ供給・simctl・adb の競合を避けるため
// 単一の直列キューで1件ずつ実行する(実機ログ解析で、全起動とタイル個別起動の並行実行により
// ブリッジ供給の waitUntilReady が失敗しゾンビブリッジが蓄積することが判明済み)。
//
// ここは vscode 非依存の純粋な状態管理のみ(spawn 自体は monitorPanel.ts 側)。常に entries[0] が
// デバイスライフサイクルのスケジューラ(running=実行中・jobs=FIFO 待機列)。
// - device ジョブは最大 DEVICE_LIFECYCLE_MAX_CONCURRENT 台まで同時実行(右クリック起動を2台並行に)。
// - bulk / restartBatch は単独占有(内部で2台並行するため、他と重ねると全体上限2を超える)。
// - 追い越しはしない(先頭が開始できない間は後続も待つ=投入順の保証)。
// - 同一デバイス名のジョブは同時に実行しない(enqueueRestart の down→up ペアの逐次性を守る)。

export type DeviceOpQueueStatus = "queued" | "running";

/** キューに積む1件のデバイスライフサイクル操作。全台(bulk)/1台(device)/複数台GPU再起動(restartBatch)の3種別。 */
export type DeviceLifecycleJob =
  // restartNames: up のみ。起動済みでも down→up する対象(devices-up --restart に渡す)。
  | { readonly kind: "bulk"; readonly op: "up" | "down"; readonly restartNames?: readonly string[] }
  // udid/serial: 未登録(マシンプロファイル未記載)デバイスの直指定(op==="down" のときのみ意味を持つ)。
  // monitorDeviceOps.ts executeDeviceOpJob が --name の代わりに --udid/--serial を渡す(対向:
  // Sources/ftester/ApiDeviceCommands.swift ApiDeviceDownDirectTarget)。name はタイル特定・
  // 重複排除キーとして直指定時も引き続き使う。
  | { readonly kind: "device"; readonly name: string; readonly op: DeviceOpKind; readonly udid?: string; readonly serial?: string }
  | { readonly kind: "restartBatch"; readonly names: readonly string[] };

/** device ジョブの同時実行上限(2台同時でホスト CPU がほぼ飽和する実測に基づくフリート共通の上限)。 */
export const DEVICE_LIFECYCLE_MAX_CONCURRENT = 2;

/** スケジューラ状態(不変)。running が実行中、jobs が待機列(FIFO)。 */
export interface DeviceLifecycleQueueState {
  readonly running: readonly DeviceLifecycleJob[];
  readonly jobs: readonly DeviceLifecycleJob[];
}

export function createDeviceLifecycleQueueState(): DeviceLifecycleQueueState {
  return { running: [], jobs: [] };
}

/** ジョブを待機列末尾に積む(新しい state を返す。実行開始は promoteDeviceLifecycleJobs)。 */
export function enqueueDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  job: DeviceLifecycleJob,
): DeviceLifecycleQueueState {
  return { running: state.running, jobs: [...state.jobs, job] };
}

/** ジョブの同一性(finish の running 照合用)。device は name+op、bulk は op、restartBatch は names。 */
function sameLifecycleJob(a: DeviceLifecycleJob, b: DeviceLifecycleJob): boolean {
  if (a.kind === "device" && b.kind === "device") {
    return a.name === b.name && a.op === b.op;
  }
  if (a.kind === "bulk" && b.kind === "bulk") {
    return a.op === b.op;
  }
  if (a.kind === "restartBatch" && b.kind === "restartBatch") {
    return a.names.length === b.names.length && a.names.every((n, i) => n === b.names[i]);
  }
  return false;
}

/** 今すぐ実行開始できる待機ジョブを running へ昇格する。started が新規開始分(呼び出し側が実処理を開始する)。 */
export function promoteDeviceLifecycleJobs(state: DeviceLifecycleQueueState): {
  readonly state: DeviceLifecycleQueueState;
  readonly started: readonly DeviceLifecycleJob[];
} {
  const running = [...state.running];
  const jobs = [...state.jobs];
  const started: DeviceLifecycleJob[] = [];
  while (jobs.length > 0) {
    const job = jobs[0];
    if (!job) {
      break;
    }
    if (job.kind === "device") {
      if (running.length >= DEVICE_LIFECYCLE_MAX_CONCURRENT) {
        break;
      }
      if (running.some((j) => j.kind !== "device")) {
        break;
      }
      if (running.some((j) => j.kind === "device" && j.name === job.name)) {
        break;
      }
      running.push(job);
      started.push(job);
      jobs.shift();
      continue;
    }
    if (running.length > 0) {
      break;
    }
    running.push(job);
    started.push(job);
    jobs.shift();
    break;
  }
  return { state: { running, jobs }, started };
}

/** 完了したジョブを running から取り除く。見つからないのはバグ(完了通知の重複等)なので例外を投げる。 */
export function finishDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  finished: DeviceLifecycleJob,
): { readonly state: DeviceLifecycleQueueState; readonly removed: DeviceLifecycleJob } {
  const index = state.running.findIndex((j) => sameLifecycleJob(j, finished));
  if (index === -1) {
    throw new Error("finishDeviceLifecycleJob: 実行中に該当ジョブがありません(完了通知が重複した可能性)");
  }
  const removed = state.running[index] as DeviceLifecycleJob;
  return {
    state: {
      running: [...state.running.slice(0, index), ...state.running.slice(index + 1)],
      jobs: state.jobs,
    },
    removed,
  };
}

/** 実行中/待機中を問わず何か積まれているか。true の間はグローバルボタン(全て起動/終了)を無効化する。 */
export function isDeviceLifecycleQueueBusy(state: DeviceLifecycleQueueState): boolean {
  return state.running.length > 0 || state.jobs.length > 0;
}

/** 指定デバイス名を対象にした device ジョブが既にキュー内(実行中含む)にあるか(連打防止に使う)。 */
export function hasDeviceLifecycleJobFor(state: DeviceLifecycleQueueState, name: string): boolean {
  return [...state.running, ...state.jobs].some(
    (job) =>
      (job.kind === "device" && job.name === name) ||
      (job.kind === "restartBatch" && job.names.includes(name)) ||
      (job.kind === "bulk" && (job.restartNames?.includes(name) ?? false)),
  );
}

/** 待機中の bulk up ジョブを1件取り除く(「デバイスの起動を中断」用。実行中(running)の bulk up は
 * プロセス kill で止める=ここでは触らない)。該当が無ければ state をそのまま返す。 */
export function removeQueuedBulkUpJob(state: DeviceLifecycleQueueState): {
  readonly state: DeviceLifecycleQueueState;
  readonly removed?: Extract<DeviceLifecycleJob, { kind: "bulk" }>;
} {
  const index = state.jobs.findIndex((job) => job.kind === "bulk" && job.op === "up");
  if (index === -1) {
    return { state };
  }
  const removed = state.jobs[index] as Extract<DeviceLifecycleJob, { kind: "bulk" }>;
  return {
    state: {
      running: state.running,
      jobs: [...state.jobs.slice(0, index), ...state.jobs.slice(index + 1)],
    },
    removed,
  };
}

/** キュー内(実行中含む)の bulk(全て起動/終了)ジョブの op。bootBusy.bulkOp の算出に使う
 * (webview は up の間 未起動タイルを「待機中」、down の間 稼働中タイルを「シャットダウン中」表示にする)。 */
export function bulkLifecycleOp(state: DeviceLifecycleQueueState): "up" | "down" | null {
  const job = [...state.running, ...state.jobs].find((job) => job.kind === "bulk");
  return job?.kind === "bulk" ? job.op : null;
}

/** 指定デバイス名の現在のキュー状態を返す(対象ジョブが無ければ undefined)。 */
export function deviceLifecycleStatusFor(
  state: DeviceLifecycleQueueState,
  name: string,
): DeviceOpBusyState | undefined {
  const all = [...state.running, ...state.jobs];
  // bulk up の restartNames(GPU 復帰対象)/ restartBatch は、ジョブが実行中でも CLI がその
  // デバイスに触れる(deviceStopping)までは「順番待ち」。per-device の実行中表示は
  // monitorDeviceOps.ts が NDJSON イベントから別途 deviceOpBusy を post する側の責務。
  if (all.some((job) => job.kind === "bulk" && (job.restartNames?.includes(name) ?? false))) {
    return { op: "down", status: "queued" };
  }
  if (all.some((job) => job.kind === "restartBatch" && job.names.includes(name))) {
    return { op: "down", status: "queued" };
  }
  const runningJob = state.running.find((job) => job.kind === "device" && job.name === name);
  if (runningJob && runningJob.kind === "device") {
    return { op: runningJob.op, status: "running" };
  }
  const queuedJob = state.jobs.find((job) => job.kind === "device" && job.name === name);
  if (queuedJob && queuedJob.kind === "device") {
    return { op: queuedJob.op, status: "queued" };
  }
  return undefined;
}

// ---- モニターの pause/resume/suppressFrames 制御 --------------------------------------------
// `ftester api monitor` は stdin から NDJSON 1行を受け付ける(Sources/ftester/ApiMonitorCommand.swift、
// 同期必須)。
// - pause/resume:「全て終了」「停止」実行中に使う。down 系ジョブの実行直前に pause・完了時に resume を
//   送り、片付け中のデバイスへスクショ取得に行くのを防ぐ(up 系は起動進行を見せるため pause しない)。
// - suppressFrames: フレーム抑制対象デバイス id 集合の全置換(差分ではない)。空配列 = 全デバイス再開。

export type MonitorControlCommand =
  | { readonly cmd: "pause" }
  | { readonly cmd: "resume" }
  | { readonly cmd: "suppressFrames"; readonly devices: readonly string[] };

/** down 系ジョブのみ true(bulk/device いずれも op フィールドで判定可能)。restartBatch は
 * up 系と同様 pause せずタイル上に進行を出す(GPU 再起動はタイル単位で見せたいため)。 */
export function deviceLifecycleJobNeedsMonitorPause(job: DeviceLifecycleJob): boolean {
  return job.kind !== "restartBatch" && job.op === "down";
}

/** モニターの stdin に書き込む制御コマンドの NDJSON 1行(末尾に改行を含む)。 */
export function monitorControlLine(cmd: MonitorControlCommand): string {
  return `${JSON.stringify(cmd)}\n`;
}
