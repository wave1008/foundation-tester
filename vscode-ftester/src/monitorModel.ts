// monitorModel.ts
// `ftester api monitor` が1行ずつ出力する NDJSON の生値(unknown)を、デバイスモニターの
// webview へ postMessage する型付きメッセージへ変換・検証する純粋関数群。
// vscode モジュールに一切依存しない(monitorPanel.ts からも test/monitorModel.test.mjs からも
// 同じロジックを使えるようにするため。ndjson.ts/stepsModel.ts と同じ方針)。
//
// 契約(別エージェント実装中の `ftester api monitor --project <P> [--interval <秒>]
// [--max-width <px>] [--profile <run>]` の stdout NDJSON):
//   {"kind":"monitorDevices","devices":[{"id":..,"name":..,"platform":"ios"|"android",
//     "state":"connected"|"booted"|"offline","detail":".."}]}   … サイクル毎
//   {"kind":"monitorFrame","device":"..","jpegBase64":"..","width":480,"height":1040}
//     … connected デバイスのみ、約interval秒毎
//   {"kind":"monitorError","device":"..","message":".."}         … device は省略されうる
//
// webview 側との通信は postMessage/onDidReceiveMessage の JSON なので、双方向のメッセージ型と
// 検証関数もここにまとめる。

export type MonitorPlatform = "ios" | "android";
export type MonitorDeviceState = "connected" | "booted" | "offline";

export interface MonitorDevice {
  readonly id: string;
  readonly name: string;
  readonly platform: MonitorPlatform;
  readonly state: MonitorDeviceState;
  readonly detail: string;
}

/** `ftester api monitor` の NDJSON 1行分のイベント(kind で判別)。 */
export type MonitorEvent =
  | { readonly kind: "monitorDevices"; readonly devices: readonly MonitorDevice[] }
  | {
      readonly kind: "monitorFrame";
      readonly device: string;
      readonly jpegBase64: string;
      readonly width: number;
      readonly height: number;
    }
  | { readonly kind: "monitorError"; readonly device?: string; readonly message: string };

const PLATFORMS: ReadonlySet<string> = new Set<MonitorPlatform>(["ios", "android"]);
const STATES: ReadonlySet<string> = new Set<MonitorDeviceState>(["connected", "booted", "offline"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isMonitorDevice(value: unknown): value is MonitorDevice {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    typeof value.state === "string" &&
    STATES.has(value.state) &&
    typeof value.detail === "string"
  );
}

/**
 * value が MonitorEvent として扱ってよいか判定する。既知の kind 以外(将来の追加や壊れた行)や
 * 必須フィールドの欠落・型不一致は false を返すので、呼び出し側は安全に無視できる。
 * (device 等、契約上省略されうるフィールドは undefined を許容する。)
 */
export function isMonitorEvent(value: unknown): value is MonitorEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "monitorDevices":
      return Array.isArray(value.devices) && value.devices.every(isMonitorDevice);
    case "monitorFrame":
      return (
        typeof value.device === "string" &&
        typeof value.jpegBase64 === "string" &&
        typeof value.width === "number" &&
        typeof value.height === "number"
      );
    case "monitorError":
      return (
        typeof value.message === "string" &&
        (value.device === undefined || typeof value.device === "string")
      );
    default:
      return false;
  }
}

/** extension → webview へ送るメッセージ(型付き)。 */
export type MonitorToWebviewMessage =
  | { readonly type: "devices"; readonly devices: readonly MonitorDevice[] }
  | {
      readonly type: "frame";
      readonly device: string;
      readonly jpegBase64: string;
      readonly width: number;
      readonly height: number;
    }
  | { readonly type: "deviceError"; readonly device?: string; readonly message: string }
  | { readonly type: "bootBusy"; readonly busy: boolean }
  | { readonly type: "processDown"; readonly message: string }
  | {
      readonly type: "deviceOpBusy";
      readonly name: string;
      readonly op: DeviceOpKind | null;
      /** キュー内での状態("running"=実行中／"queued"=順番待ち)。op が null のときは null。 */
      readonly status: DeviceOpQueueStatus | null;
    }
  | { readonly type: "deviceOpFailed"; readonly name: string; readonly message: string }
  | {
      readonly type: "profileInfo";
      /** 対象プロジェクトの実行プロファイル名一覧(Projects/<project>/profiles/runs/ 直下)。 */
      readonly profiles: readonly string[];
      /** 現在の ftester.profile 設定値。"" はプロファイルなし。 */
      readonly current: string;
    };

/** 検証済みの MonitorEvent を、webview へそのまま postMessage できる形に変換する。 */
export function toWebviewMessage(event: MonitorEvent): MonitorToWebviewMessage {
  switch (event.kind) {
    case "monitorDevices":
      return { type: "devices", devices: event.devices };
    case "monitorFrame":
      return {
        type: "frame",
        device: event.device,
        jpegBase64: event.jpegBase64,
        width: event.width,
        height: event.height,
      };
    case "monitorError":
      return { type: "deviceError", device: event.device, message: event.message };
  }
}

/** webview → extension へ送るメッセージ(ボタン操作)。 */
export type MonitorFromWebviewMessage =
  // webview スクリプトの初期化完了(全リスナー登録済み)を拡張側へ通知する。これを受けてから
  // 拡張側は初期状態(laneHydrate/profileInfo等)を送る(ready ハンドシェイク。html設定直後の
  // postMessage はリスナー登録前のレースで捨てられるため、一度きりの送信はこの通知を待つ)。
  | { readonly type: "ready" }
  | { readonly type: "devicesUp" }
  | { readonly type: "devicesDown" }
  | { readonly type: "restartMonitor" }
  | { readonly type: "deviceOp"; readonly name: string; readonly op: DeviceOpKind }
  | { readonly type: "selectProfile"; readonly profile: string }
  // 実行プロファイルの追加/コピー/編集/削除(ツールバーの各ボタン)。コピー/編集/削除の対象は
  // profile(空文字は「対象なし」= 不正入力として扱うため、検証で弾く)。
  | { readonly type: "profileAdd" }
  | { readonly type: "profileCopy"; readonly profile: string }
  | { readonly type: "profileEdit"; readonly profile: string }
  | { readonly type: "profileDelete"; readonly profile: string };

/** webview からの postMessage 値を MonitorFromWebviewMessage として扱ってよいか判定する。 */
export function isMonitorFromWebviewMessage(value: unknown): value is MonitorFromWebviewMessage {
  if (!isRecord(value) || typeof value.type !== "string") {
    return false;
  }
  switch (value.type) {
    case "ready":
    case "devicesUp":
    case "devicesDown":
    case "restartMonitor":
    case "profileAdd":
      return true;
    case "deviceOp":
      return typeof value.name === "string" && (value.op === "up" || value.op === "down");
    case "selectProfile":
      return typeof value.profile === "string";
    case "profileCopy":
    case "profileEdit":
    case "profileDelete":
      // 空文字は「対象プロファイルなし」なので不正入力として弾く(selectProfile と違い、
      // これら3種は必ず既存プロファイルを1件指すため)。
      return typeof value.profile === "string" && value.profile !== "";
    default:
      return false;
  }
}

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

/**
 * タイル右クリックメニューの唯一の項目(起動/停止)の表示状態。
 * op は実際にクリックした際に実行する操作(disabled:true の間はクリック不可)。
 */
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
 * モニターの devices サイクルで届く state と、そのデバイスの現在のキュー状態(busy。無ければ
 * undefined)から、タイル右クリックメニューに表示する唯一の項目を決める
 * (monitorPanel.ts のコンテキストメニュー・実行中バッジ・webview 複製が使う)。
 * busy が無い場合、offline なら「起動」(op:"up")、connected/booted なら「停止」(op:"down")。
 * busy.status が "queued"(直列キューの順番待ち)なら「待機中...」、"running"(実行中)なら
 * その操作に応じた「起動中...」/「停止中...」になる(どちらも disabled:true)。
 * MonitorDeviceState の全パターンをカバーするため null にはならない。
 */
export function deviceOpMenuItem(
  state: MonitorDeviceState,
  busy: DeviceOpBusyState | undefined,
): DeviceOpMenuItem {
  if (busy?.status === "queued") {
    return { label: "待機中...", op: busy.op, disabled: true };
  }
  if (busy?.op === "up") {
    return { label: "起動中...", op: "up", disabled: true };
  }
  if (busy?.op === "down") {
    return { label: "停止中...", op: "down", disabled: true };
  }
  return state === "offline"
    ? { label: "起動", op: "up", disabled: false }
    : { label: "停止", op: "down", disabled: false };
}

// ---- デバイスライフサイクル操作の直列キュー ------------------------------------------------
// 「デバイスを全て起動/終了」(bulk)とタイル個別の起動/停止(device)は、ブリッジ供給・simctl・adb
// が競合しないよう単一の直列キューで1件ずつ実行する(FTAndroid の DeviceBooter.bootAll が
// 負荷ゲート+直列ブリッジ供給で並行起動時の競合を避けているのと同じ思想。実機ログ解析で、
// 「デバイスを全て起動」とタイル右クリックの個別起動が並行実行されるとブリッジ供給の
// waitUntilReady が失敗し、ゾンビブリッジが蓄積することが分かっている)。
//
// ここでは実際のプロセス起動(spawn)は行わない、vscode 非依存の純粋な状態管理だけを持つ。
// monitorPanel.ts が enqueueDeviceLifecycleJob で積んだジョブを deviceLifecycleQueueHead() で
// 取り出して実行し、完了したら dequeueDeviceLifecycleJob() で先頭を取り除いて次を実行する
// (常に entries[0] が「現在実行中のジョブ」という不変条件を保つ FIFO)。

export type DeviceOpQueueStatus = "queued" | "running";

/** キューに積む1件のデバイスライフサイクル操作。全台(bulk)/1台(device)の2種別。 */
export type DeviceLifecycleJob =
  | { readonly kind: "bulk"; readonly op: "up" | "down" }
  | { readonly kind: "device"; readonly name: string; readonly op: DeviceOpKind };

/** 直列キューの状態(不変)。jobs[0] が実行中、それ以降が待機中。 */
export interface DeviceLifecycleQueueState {
  readonly jobs: readonly DeviceLifecycleJob[];
}

export function createDeviceLifecycleQueueState(): DeviceLifecycleQueueState {
  return { jobs: [] };
}

/** ジョブをキュー末尾に積む(新しい state を返す。呼び出し側は戻り値で置き換えること)。 */
export function enqueueDeviceLifecycleJob(
  state: DeviceLifecycleQueueState,
  job: DeviceLifecycleJob,
): DeviceLifecycleQueueState {
  return { jobs: [...state.jobs, job] };
}

/** 実行完了したジョブ(先頭)をキューから取り除く。空のキューに対して呼ぶのはバグなので例外を投げる。 */
export function dequeueDeviceLifecycleJob(state: DeviceLifecycleQueueState): DeviceLifecycleQueueState {
  if (state.jobs.length === 0) {
    throw new Error("dequeueDeviceLifecycleJob: キューが空です(先頭ジョブの完了通知が重複した可能性)");
  }
  return { jobs: state.jobs.slice(1) };
}

/** キューに何か(実行中含む)積まれているか。true の間はグローバルボタン(全て起動/終了)を無効化する。 */
export function isDeviceLifecycleQueueBusy(state: DeviceLifecycleQueueState): boolean {
  return state.jobs.length > 0;
}

/** 先頭(=現在実行すべき/実行中の)ジョブ。キューが空なら undefined。 */
export function deviceLifecycleQueueHead(state: DeviceLifecycleQueueState): DeviceLifecycleJob | undefined {
  return state.jobs[0];
}

/** 指定デバイス名を対象にした device ジョブが既にキュー内(実行中含む)にあるか(連打防止に使う)。 */
export function hasDeviceLifecycleJobFor(state: DeviceLifecycleQueueState, name: string): boolean {
  return state.jobs.some((job) => job.kind === "device" && job.name === name);
}

/**
 * 指定デバイス名の現在のキュー状態(実行中/待機中)を返す。対象ジョブが無ければ undefined。
 * 先頭(index 0)なら "running"、それ以外(まだ順番が回ってきていない)なら "queued"。
 */
export function deviceLifecycleStatusFor(
  state: DeviceLifecycleQueueState,
  name: string,
): DeviceOpBusyState | undefined {
  const index = state.jobs.findIndex((job) => job.kind === "device" && job.name === name);
  if (index === -1) {
    return undefined;
  }
  const job = state.jobs[index];
  if (!job || job.kind !== "device") {
    return undefined;
  }
  return { op: job.op, status: index === 0 ? "running" : "queued" };
}

// ---- モニターの pause/resume 制御(パネル発の「全て終了」「停止」実行中に使う) ---------------
// `ftester api monitor` は stdin から NDJSON 1行で {"cmd":"pause"} / {"cmd":"resume"} を
// 受け付ける(Sources/ftester/ApiMonitorCommand.swift 参照)。down 系ジョブ(bulk down /
// device-down)の実行直前に pause、完了時(成功・失敗問わず)に resume を送ることで、片付け中の
// デバイスへモニターがスクショ取得に行って過渡的な警告を吐くのを防ぐ。up 系ジョブ(bulk up /
// device-up)では pause しない(起動進行をタイルで見たいため)。

export type MonitorControlCommand = "pause" | "resume";

/**
 * ジョブの実行前後でモニターの pause/resume が必要かどうか(down 系のみ true)。
 * bulk/device いずれのジョブも op フィールドが "up" | "down" で共通なので、job.kind に
 * 関わらず単純に op で判定できる。
 */
export function deviceLifecycleJobNeedsMonitorPause(job: DeviceLifecycleJob): boolean {
  return job.op === "down";
}

/** モニターの stdin に書き込む制御コマンドの NDJSON 1行(末尾に改行を含む)。 */
export function monitorControlLine(cmd: MonitorControlCommand): string {
  return `${JSON.stringify({ cmd })}\n`;
}

// ---- 実行プロファイル切り替え時の自動シャットダウン対象算出 ------------------------------------
// 要件: プロファイル切り替え(ftester.profile 変更)で「デバイスを全て起動/終了」ボタンの対象が
// 新プロファイルのデバイスに変わるのに合わせて、切り替え先プロファイルに定義されていない
// 稼働中デバイスはシャットダウンする。逆に、切り替え先プロファイルに定義されているデバイスは
// (稼働中でも offline でも)一切触らない — 自動起動はしない。稼働中ならそのまま利用を続けられる
// ようにする(monitorPanel.ts の restartMonitorIfScopeChanged がこの結果を down ジョブとしてキューに積む)。

/**
 * 直近に観測されたデバイス一覧(旧スコープの最終観測)と、切り替え先プロファイルのデバイス名一覧
 * (null = プロファイルなし = 全デバイスが対象なので何も止めない)から、シャットダウンすべき
 * デバイス名を返す(元の順序を保つ)。
 * - newScopeNames が null: [](絞り込みが無くなる=全デバイスが対象内なので停止対象なし)。
 * - それ以外: state が "offline" でない(=稼働中の) かつ newScopeNames に含まれない name。
 *   ("offline" のデバイスは既に停止しているので対象外。newScopeNames に含まれるデバイスは
 *   稼働中でもそのまま — 自動起動しないのと対で、自動停止もしない。)
 */
export function devicesToShutdownOnScopeChange(
  devices: readonly MonitorDevice[],
  newScopeNames: readonly string[] | null,
): string[] {
  if (newScopeNames === null) {
    return [];
  }
  const keep = new Set(newScopeNames);
  return devices.filter((device) => device.state !== "offline" && !keep.has(device.name)).map((device) => device.name);
}

// ---- 実行プロファイルの追加/コピー(名前検証・テンプレート生成) ------------------------------
// monitorPanel.ts の profileAdd/profileCopy ハンドラが使う純粋ロジック。ファイルI/O自体は
// vscode 依存(fs)なので monitorPanel.ts 側で行い、ここでは「名前が妥当か」「初期内容は何か」
// だけを扱う(config.ts の listRunProfileNames 等と同じ、vscode 非依存の方針)。

/**
 * 新規/コピー先の実行プロファイル名(runs/<name>.json の <name>)として妥当かどうかを検証する。
 * showInputBox の validateInput にそのまま渡せる形(問題なければ null、そうでなければ表示用の
 * 日本語エラーメッセージ)。呼び出し側は trim 済みの値を渡すこと(このためnameがtrim結果と
 * 一致しない=前後に空白を含む入力も、それ自体を不正として弾く。呼び出し側の trim 有無に
 * 依存しない防御的な検証にするため)。
 * 不正となる条件(優先順に判定):
 * - 前後に空白を含む(=trim済みでない)
 * - 空文字
 * - "/" または "\" を含む(runs/<name>.json のファイル名になるため、パス区切りは使えない)
 * - "." で始まる(隠しファイル的な名前を避ける)
 * - existing(既存プロファイル名一覧)に含まれる(重複)
 */
export function validateNewRunProfileName(name: string, existing: readonly string[]): string | null {
  if (name !== name.trim()) {
    return "プロファイル名の前後に空白を含めることはできません。";
  }
  if (name.length === 0) {
    return "プロファイル名を入力してください。";
  }
  if (name.includes("/") || name.includes("\\")) {
    return 'プロファイル名に "/" や "\\" は使えません。';
  }
  if (name.startsWith(".")) {
    return 'プロファイル名を "." で始めることはできません。';
  }
  if (existing.includes(name)) {
    return `実行プロファイル「${name}」は既に存在します。`;
  }
  return null;
}

/**
 * 新規実行プロファイル(runs/<name>.json)の初期内容(整形済みJSON文字列、末尾改行あり)を作る。
 * app は appNames の先頭(候補が無ければ空文字。ユーザーが編集画面で埋める前提)、devices は
 * machineDeviceNames から `{"name": ...}` の配列を作る(候補が無ければ空文字1件のプレースホルダー)。
 * heal/reportDir はスキーマの既定値をそのまま書き出す。
 */
export function buildRunProfileTemplate(
  appNames: readonly string[],
  machineDeviceNames: readonly string[],
): string {
  const app = appNames[0] ?? "";
  const devices =
    machineDeviceNames.length > 0
      ? machineDeviceNames.map((name) => ({ name }))
      : [{ name: "" }];
  const template = { app, devices, heal: false, reportDir: "reports" };
  return `${JSON.stringify(template, null, 2)}\n`;
}
