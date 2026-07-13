// liveModel.ts
// ライブ操作パネル(livePanel.ts)向けの vscode 非依存ロジック(検証・型定義・座標変換・
// webview プロトコル)。
//
// 契約(Sources/ftester/ApiListDevicesCommand.swift・ApiLiveCommand.swift):
//   `ftester api list-devices --project <p>`: 成功時は stdout 1行JSON、失敗時
//   (マシンプロファイル未設定等)は stdout 出力なし・非0終了(診断は stderr のみ)。
//   各デバイスの udid: iOS は解決済みシミュレータ UDID、Android・解決失敗は null
//   (ApiListDevicesCommand.swift 参照。live serve --udid の自動起動判定に使う)。
//   `ftester api live serve --platform <p> [--port <n>|--serial <s>]`(常駐。stdin から NDJSON で
//   コマンドを1行ずつ受け、逐次処理する。コマンド/イベントの形は LiveServeCommand/LiveServeEvent
//   型を参照): イベントは refresh 以外は actionResult→snapshot の順で2行、refresh は snapshot の
//   1行のみ(parseLiveServeEvent が "kind" で判別)。
//   frame は画像のみの frame イベント1行(AXツリーは取らない。自動画面更新用)。

import type { MonitorDeviceState, MonitorPlatform } from "./monitorModel";

export type LivePlatform = MonitorPlatform;
/** list-devices の state 語彙は ApiMonitorCommand.determineStates と同一(monitorModel.ts を再利用)。 */
export type LiveDeviceState = MonitorDeviceState;

const PLATFORMS: ReadonlySet<string> = new Set<LivePlatform>(["ios", "android"]);
const DEVICE_STATES: ReadonlySet<string> = new Set<LiveDeviceState>(["connected", "booted", "offline"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// ---- list-devices ------------------------------------------------------------------

export interface LiveDevice {
  readonly name: string;
  readonly platform: LivePlatform;
  readonly state: LiveDeviceState;
  readonly detail: string;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
}

export interface ListDevicesResult {
  readonly project: string;
  readonly machine: string;
  readonly devices: readonly LiveDevice[];
}

function isLiveDevice(value: unknown): value is LiveDevice {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.name === "string" &&
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    typeof value.state === "string" &&
    DEVICE_STATES.has(value.state) &&
    typeof value.detail === "string" &&
    (value.port === null || typeof value.port === "number") &&
    (value.serial === null || typeof value.serial === "string") &&
    (value.udid === null || typeof value.udid === "string")
  );
}

export function isListDevicesResult(value: unknown): value is ListDevicesResult {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.project === "string" &&
    typeof value.machine === "string" &&
    Array.isArray(value.devices) &&
    value.devices.every(isLiveDevice)
  );
}

export function parseListDevicesResult(value: unknown): ListDevicesResult | undefined {
  return isListDevicesResult(value) ? value : undefined;
}

// ---- live snapshot / アクション共通 ----------------------------------------------------

export interface LiveRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface LiveSize {
  readonly width: number;
  readonly height: number;
}

export interface LivePoint {
  readonly x: number;
  readonly y: number;
}

export interface LiveElement {
  readonly ref: number;
  readonly type: string;
  readonly label: string | null;
  readonly identifier: string | null;
  readonly value: string | null;
  readonly frame: LiveRect;
}

export interface LiveSnapshot {
  readonly ok: true;
  readonly platform: string;
  readonly screen: LiveSize;
  readonly image: string;
  readonly elements: readonly LiveElement[];
}

export interface LiveOkResult {
  readonly ok: true;
}

export interface LiveErrorResult {
  readonly ok: false;
  readonly error: string;
}

export type LiveActionResult = LiveOkResult | LiveErrorResult;

function isLiveRect(value: unknown): value is LiveRect {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.x === "number" &&
    typeof value.y === "number" &&
    typeof value.width === "number" &&
    typeof value.height === "number"
  );
}

function isLiveElement(value: unknown): value is LiveElement {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.ref === "number" &&
    typeof value.type === "string" &&
    (value.label === null || typeof value.label === "string") &&
    (value.identifier === null || typeof value.identifier === "string") &&
    (value.value === null || typeof value.value === "string") &&
    isLiveRect(value.frame)
  );
}

export function isLiveSnapshot(value: unknown): value is LiveSnapshot {
  if (!isRecord(value) || value.ok !== true) {
    return false;
  }
  return (
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    isRecord(value.screen) &&
    typeof value.screen.width === "number" &&
    typeof value.screen.height === "number" &&
    typeof value.image === "string" &&
    Array.isArray(value.elements) &&
    value.elements.every(isLiveElement)
  );
}

export function isLiveErrorResult(value: unknown): value is LiveErrorResult {
  if (!isRecord(value) || value.ok !== false) {
    return false;
  }
  return typeof value.error === "string";
}

export function isLiveOkResult(value: unknown): value is LiveOkResult {
  return isRecord(value) && value.ok === true;
}

export function parseLiveSnapshotResult(value: unknown): LiveSnapshot | LiveErrorResult | undefined {
  if (isLiveSnapshot(value)) {
    return value;
  }
  if (isLiveErrorResult(value)) {
    return value;
  }
  return undefined;
}

export interface LiveFrame {
  readonly ok: true;
  readonly image: string;
}
export type LiveFrameResult = LiveFrame | LiveErrorResult;

export function parseLiveFrameResult(value: unknown): LiveFrameResult | undefined {
  if (isRecord(value) && value.ok === true && typeof value.image === "string") {
    return { ok: true, image: value.image };
  }
  if (isLiveErrorResult(value)) {
    return value;
  }
  return undefined;
}

export function parseLiveActionResult(value: unknown): LiveActionResult | undefined {
  if (isLiveOkResult(value)) {
    return { ok: true };
  }
  if (isLiveErrorResult(value)) {
    return value;
  }
  return undefined;
}

// ---- live serve(常駐プロセス)のコマンド組み立て・イベント検証(契約はファイル冒頭参照) -----------

export type LiveServeCommand =
  | { readonly cmd: "tap"; readonly ref: number }
  | { readonly cmd: "tap"; readonly x: number; readonly y: number }
  | { readonly cmd: "type"; readonly text: string; readonly ref: number | null }
  | {
      readonly cmd: "drag";
      readonly fromX: number;
      readonly fromY: number;
      readonly toX: number;
      readonly toY: number;
      readonly press: number;
      readonly duration: number;
    }
  | { readonly cmd: "press"; readonly x: number; readonly y: number; readonly duration: number }
  | { readonly cmd: "appSwitcher" }
  | { readonly cmd: "home" }
  | { readonly cmd: "terminate" }
  | { readonly cmd: "refresh" }
  | { readonly cmd: "frame" }
  | { readonly cmd: "launch"; readonly bundle: string }
  | { readonly cmd: "install"; readonly path: string };

/** serve の stdin へ書き込む1行(末尾改行付き)を組み立てる。 */
export function serializeLiveServeCommand(command: LiveServeCommand): string {
  return `${JSON.stringify(command)}\n`;
}

export type LiveServeEvent =
  | { readonly kind: "actionResult"; readonly result: LiveActionResult }
  | { readonly kind: "snapshot"; readonly result: LiveSnapshot | LiveErrorResult }
  | { readonly kind: "frame"; readonly result: LiveFrameResult };

/**
 * NDJSON 1行を "kind" で actionResult/snapshot に振り分ける。中身の検証は
 * parseLiveActionResult/parseLiveSnapshotResult に委ねるが、それらの戻り値には envelope 側の
 * "kind" が残らないため、ここで詰め直す。判別不能なら undefined。
 */
export function parseLiveServeEvent(value: unknown): LiveServeEvent | undefined {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return undefined;
  }
  if (value.kind === "actionResult") {
    const result = parseLiveActionResult(value);
    if (!result) {
      return undefined;
    }
    return { kind: "actionResult", result: result.ok ? { ok: true } : { ok: false, error: result.error } };
  }
  if (value.kind === "snapshot") {
    const result = parseLiveSnapshotResult(value);
    if (!result) {
      return undefined;
    }
    return {
      kind: "snapshot",
      result: result.ok
        ? {
            ok: true,
            platform: result.platform,
            screen: result.screen,
            image: result.image,
            elements: result.elements,
          }
        : { ok: false, error: result.error },
    };
  }
  if (value.kind === "frame") {
    const result = parseLiveFrameResult(value);
    if (!result) {
      return undefined;
    }
    return {
      kind: "frame",
      result: result.ok
        ? { ok: true, image: result.image }
        : { ok: false, error: result.error },
    };
  }
  return undefined;
}

// ---- 座標変換 ---------------------------------------------------------------------------
// 契約: screen/frame はポイント座標、表示側は画像左上を原点とする表示px。画像は screen の
// アスペクト比のままレターボックス無しで表示される前提(ftester-gui/LiveView.swift の
// ScreenshotView と同じ)。

/** クリック位置(表示px)→ ポイント座標(GUI版 ScreenshotView.gesture と同じ比例変換)。
 * 範囲外クリックでも screen の範囲にクランプする。 */
export function pointFromClick(click: LivePoint, display: LiveSize, screen: LiveSize): LivePoint {
  if (display.width <= 0 || display.height <= 0 || screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0 };
  }
  const x = (click.x / display.width) * screen.width;
  const y = (click.y / display.height) * screen.height;
  return {
    x: Math.min(Math.max(x, 0), screen.width),
    y: Math.min(Math.max(y, 0), screen.height),
  };
}

/** ポイント座標→表示pxの矩形(pointFromClick の逆変換)。要素一覧ホバー時の枠オーバーレイに使う。 */
export function frameToDisplayRect(frame: LiveRect, screen: LiveSize, display: LiveSize): LiveRect {
  if (screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scaleX = display.width / screen.width;
  const scaleY = display.height / screen.height;
  return {
    x: frame.x * scaleX,
    y: frame.y * scaleY,
    width: frame.width * scaleX,
    height: frame.height * scaleY,
  };
}

/** テキスト入力系の型語彙(タップ→入力欄フォーカス判定に使う)。契約: Sources/FTCore/
 * SnapshotRendering.swift の textInputTypes と同一(iOS の BridgeRouter/InAppSnapshot と
 * Android の SnapshotBuilder が同じ語彙へ正規化する)。変更したら Swift 側も追随させること。 */
const TEXT_INPUT_TYPES: ReadonlySet<string> = new Set(["TextField", "SecureTextField", "TextView", "SearchField"]);

/** 要素がテキスト入力欄(タップするとキーボード入力対象になる)かどうか。 */
export function isTextInputElement(element: LiveElement): boolean {
  return TEXT_INPUT_TYPES.has(element.type);
}

/** click の変換先ポイント座標を含む要素のうち、面積最小のもの(=重なりの中で最も具体的なもの)を返す。
 * 一致なしは undefined(レコーディング時、対象要素が無いタップ・長押しは記録しない判定に使う)。 */
export function hitTestElement(point: LivePoint, elements: readonly LiveElement[]): LiveElement | undefined {
  let best: LiveElement | undefined;
  let bestArea = Infinity;
  for (const element of elements) {
    const { frame } = element;
    if (point.x < frame.x || point.x > frame.x + frame.width || point.y < frame.y || point.y > frame.y + frame.height) {
      continue;
    }
    const area = frame.width * frame.height;
    if (area < bestArea) {
      bestArea = area;
      best = element;
    }
  }
  return best;
}

// ---- レコーディング → FlowStep 変換(契約: Sources/FTCore/Flow.swift。gen-scenario --steps の入力) ----

/** Flow.swift FlowLocator の使用フィールドのみ(raw は生成側では使わない)。 */
export interface FlowLocatorShape {
  readonly id?: string;
  readonly label?: string;
  readonly type?: string;
  readonly index?: number;
}

/** Flow.swift FlowStep の使用フィールドのみ。gen-scenario --steps に渡す JSON 配列の要素形。
 * home/appSwitcher/terminate はロケータ無し(ScenarioCodeGen が home()/appSwitcher()/terminateApp() に写像)。 */
export interface RecordedStep {
  readonly action: "tap" | "type" | "press" | "swipe" | "home" | "appSwitcher" | "terminate";
  readonly locator?: FlowLocatorShape;
  readonly fallbacks?: readonly FlowLocatorShape[];
  readonly text?: string;
  readonly direction?: "up" | "down" | "left" | "right";
}

/**
 * 契約: Sources/FTCore/Flow.swift FlowLocatorBuilder.chain と同じ優先度(同期対象):
 * identifier > label > (同じ type 内での位置)index。全て無ければ type+index:0 のみを返す。
 * ただし id があるときは位置依存の type+index フォールバックは足さない(id は安定なので
 * `.TextField` 等は冗長・ノイズ。生成コードの `#id||.Type` を `#id` にする)。
 */
export function locatorChainForElement(
  element: LiveElement,
  elements: readonly LiveElement[],
): { locator: FlowLocatorShape; fallbacks: FlowLocatorShape[] } {
  const locators: FlowLocatorShape[] = [];
  let hasId = false;
  if (element.identifier !== null && element.identifier.length > 0) {
    locators.push({ id: element.identifier });
    hasId = true;
  }
  if (element.label !== null && element.label.length > 0) {
    locators.push({ label: element.label });
  }
  if (!hasId) {
    const sameType = elements.filter((e) => e.type === element.type);
    const index = sameType.findIndex((e) => e.ref === element.ref);
    if (index !== -1) {
      locators.push({ type: element.type, index });
    }
  }
  if (locators.length === 0) {
    locators.push({ type: element.type, index: 0 });
  }
  return { locator: locators[0]!, fallbacks: locators.slice(1) };
}

// ---- gen-scenario(レコーディング→シナリオ生成)NDJSON イベント ---------------------------------
// 契約: `ftester api gen-scenario --project <p> --steps <path>` の stdout NDJSON。

export type GenScenarioEvent =
  | { readonly event: "scenarioGenerated"; readonly file: string; readonly className: string }
  | { readonly event: "error"; readonly message: string };

/** "genStarted" 等の未知イベントは undefined(呼び出し側で無視する)。 */
export function parseGenScenarioEvent(value: unknown): GenScenarioEvent | undefined {
  if (!isRecord(value) || typeof value.event !== "string") {
    return undefined;
  }
  if (value.event === "scenarioGenerated" && typeof value.file === "string" && typeof value.className === "string") {
    return { event: "scenarioGenerated", file: value.file, className: value.className };
  }
  if (value.event === "error" && typeof value.message === "string") {
    return { event: "error", message: value.message };
  }
  return undefined;
}

// ---- 要素一覧の1行表示フォーマット --------------------------------------------------------

/**
 * 要素一覧の1行の表示テキストを組み立てる(ftester-gui/LiveView.swift の elementLine と同じ形式:
 * `[ref] type「label」id=identifier =value`。label/identifier/value が空・null のフィールドは省く)。
 */
export function formatElementLine(element: LiveElement): string {
  const parts = [`[${element.ref}]`, element.type];
  if (element.label !== null && element.label.length > 0) {
    parts.push(`「${element.label}」`);
  }
  if (element.identifier !== null && element.identifier.length > 0) {
    parts.push(`id=${element.identifier}`);
  }
  if (element.value !== null && element.value.length > 0) {
    parts.push(`=${element.value}`);
  }
  return parts.join(" ");
}

// ---- デバイス → CLI引数組み立て -----------------------------------------------------------

export interface LiveDeviceRef {
  readonly platform: LivePlatform;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
}

/** udid は含めない: monitorExploreController も共用しており `api explore` 系は --udid を
 * 受け付けない(--udid は monitorLiveController.ts が `api live serve` 呼び出し時に個別に付与する)。 */
export function buildDeviceArgs(device: LiveDeviceRef): string[] {
  const args = ["--platform", device.platform];
  if (device.platform === "ios") {
    if (device.port !== null && device.port > 0) {
      args.push("--port", String(device.port));
    }
  } else if (device.serial !== null && device.serial.trim().length > 0) {
    args.push("--serial", device.serial.trim());
  }
  return args;
}

/** デバイス参照の同一性判定(livePanel.ts の serve 再バインド要否判定に使う)。 */
export function sameLiveDeviceRef(a: LiveDeviceRef, b: LiveDeviceRef): boolean {
  return a.platform === b.platform && a.port === b.port && a.serial === b.serial && a.udid === b.udid;
}

/** ftester.platform/port/serial 設定から作る「設定のデバイス」フォールバックの元データ。 */
export interface FallbackDeviceSource {
  readonly platform: LivePlatform;
  /** FtesterConfig.port と同じ規約: 0 は未指定。 */
  readonly port: number;
  /** FtesterConfig.serial と同じ規約: 空文字列は未指定。 */
  readonly serial: string;
}

export function buildFallbackDevice(source: FallbackDeviceSource): LiveDeviceRef {
  return {
    platform: source.platform,
    port: source.port > 0 ? source.port : null,
    serial: source.serial.trim().length > 0 ? source.serial.trim() : null,
    udid: null,
  };
}

// ---- デバイス選択UI向けのオプション -----------------------------------------------------

/** list-devices 由来の state に加え、フォールバック(設定のデバイス)用に "unknown" を許容する。 */
export type LiveDeviceOptionState = LiveDeviceState | "unknown";

export interface LiveDeviceOption {
  readonly id: string;
  readonly name: string;
  readonly platform: LivePlatform;
  readonly state: LiveDeviceOptionState;
  readonly detail: string;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
}

/** id はデバイス名(machines プロファイル検証で ios/android 横断の一意性が保証済み)を使うため、
 * 一覧の並び替え・再取得を挟んでも選択状態を維持できる。 */
export function devicesToOptions(devices: readonly LiveDevice[]): LiveDeviceOption[] {
  return devices.map((device) => ({
    id: `${device.platform}:${device.name}`,
    name: device.name,
    platform: device.platform,
    state: device.state,
    detail: device.detail,
    port: device.port,
    serial: device.serial,
    udid: device.udid,
  }));
}

export const FALLBACK_DEVICE_ID = "config-fallback";

export function fallbackDeviceOption(source: FallbackDeviceSource): LiveDeviceOption {
  const ref = buildFallbackDevice(source);
  return {
    id: FALLBACK_DEVICE_ID,
    name: "設定のデバイス",
    platform: ref.platform,
    state: "unknown",
    detail: "ftester.platform/port/serial 設定から作成",
    port: ref.port,
    serial: ref.serial,
    udid: ref.udid,
  };
}

// ---- webview メッセージプロトコル ---------------------------------------------------------

/** webview へ渡す要素一覧の1件分(表示テキストを host 側で事前整形して付与する)。 */
export interface LiveElementView extends LiveElement {
  readonly line: string;
}

export type LiveToWebviewMessage =
  | {
      readonly type: "devices";
      readonly devices: readonly LiveDeviceOption[];
      readonly selectedId: string | undefined;
    }
  | { readonly type: "banner"; readonly message: string | null }
  | {
      readonly type: "snapshot";
      readonly platform: string;
      readonly screen: LiveSize;
      readonly image: string;
      readonly elements: readonly LiveElementView[];
    }
  | { readonly type: "frame"; readonly image: string }
  | { readonly type: "actionError"; readonly message: string }
  | { readonly type: "busy"; readonly busy: boolean }
  | { readonly type: "connection"; readonly connected: boolean; readonly message: string | null }
  | { readonly type: "busyOverlay"; readonly message: string | null }
  | {
      readonly type: "appProfiles";
      readonly profiles: readonly string[];
      readonly selectedId: string | undefined;
    }
  | { readonly type: "recording"; readonly active: boolean; readonly generating?: boolean }
  | { readonly type: "recordStatus"; readonly message: string; readonly file: string | null }
  // テキスト入力欄をタップした直後に「入力するテキスト」欄へフォーカスを移す指示(受け手: liveTab.js)。
  | { readonly type: "focusTypeInput" };

export function toSnapshotMessage(snapshot: LiveSnapshot): LiveToWebviewMessage {
  return {
    type: "snapshot",
    platform: snapshot.platform,
    screen: snapshot.screen,
    image: snapshot.image,
    elements: snapshot.elements.map((element) => ({ ...element, line: formatElementLine(element) })),
  };
}

export type LiveFromWebviewMessage =
  | { readonly type: "refreshDevices" }
  | { readonly type: "selectDevice"; readonly id: string }
  | { readonly type: "openDevice"; readonly id: string }
  | { readonly type: "refreshSnapshot" }
  | {
      readonly type: "tapPoint";
      readonly clickX: number;
      readonly clickY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
    }
  | {
      readonly type: "pressPoint";
      readonly clickX: number;
      readonly clickY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
      readonly holdMs: number;
    }
  | {
      readonly type: "dragPoints";
      readonly fromX: number;
      readonly fromY: number;
      readonly toX: number;
      readonly toY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
      readonly pressMs: number;
      readonly dragMs: number;
    }
  | { readonly type: "tapRef"; readonly ref: number }
  | { readonly type: "typeText"; readonly text: string; readonly ref: number | null }
  | { readonly type: "appSwitcher" }
  | { readonly type: "home" }
  | { readonly type: "visibility"; readonly visible: boolean }
  | { readonly type: "refreshAppProfiles" }
  | { readonly type: "startRecord"; readonly appProfile: string; readonly autoInstall: boolean }
  | { readonly type: "stopRecord" };

export function isLiveFromWebviewMessage(value: unknown): value is LiveFromWebviewMessage {
  if (!isRecord(value) || typeof value.type !== "string") {
    return false;
  }
  switch (value.type) {
    case "refreshDevices":
    case "refreshSnapshot":
    case "appSwitcher":
    case "home":
    case "refreshAppProfiles":
    case "stopRecord":
      return true;
    case "selectDevice":
    case "openDevice":
      return typeof value.id === "string";
    case "tapPoint":
      return (
        typeof value.clickX === "number" &&
        typeof value.clickY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number"
      );
    case "pressPoint":
      return (
        typeof value.clickX === "number" &&
        typeof value.clickY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number" &&
        typeof value.holdMs === "number"
      );
    case "dragPoints":
      return (
        typeof value.fromX === "number" &&
        typeof value.fromY === "number" &&
        typeof value.toX === "number" &&
        typeof value.toY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number" &&
        typeof value.pressMs === "number" &&
        typeof value.dragMs === "number"
      );
    case "tapRef":
      return typeof value.ref === "number";
    case "typeText":
      return typeof value.text === "string" && (value.ref === null || typeof value.ref === "number");
    case "visibility":
      return typeof value.visible === "boolean";
    case "startRecord":
      return typeof value.appProfile === "string" && typeof value.autoInstall === "boolean";
    default:
      return false;
  }
}

// ---- モニターwebviewとの多重化封筒 --------------------------------------------------------
// モニターパネル(monitorPanel.ts)は1つのwebviewに複数機能のメッセージが行き交うため、live系は
// type:"live" で包んで monitor系メッセージ型(monitorModel.ts)との衝突を避ける。
// 対向: src/webview/monitor/liveTab.js

/** webview → host。 */
export interface LiveWebviewEnvelope {
  readonly type: "live";
  readonly message: LiveFromWebviewMessage;
}

export function isLiveWebviewEnvelope(value: unknown): value is LiveWebviewEnvelope {
  return isRecord(value) && value.type === "live" && isLiveFromWebviewMessage(value.message);
}

/** host → webview。 */
export interface LiveToWebviewEnvelope {
  readonly type: "live";
  readonly message: LiveToWebviewMessage;
}
