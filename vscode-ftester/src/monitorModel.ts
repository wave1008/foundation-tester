// monitorModel.ts
// `ftester api monitor` が1行ずつ出力する NDJSON の生値(unknown)を、デバイスモニターの
// webview へ postMessage する型付きメッセージへ変換・検証する純粋関数群。
// vscode モジュールに一切依存しない(monitorPanel.ts からも test/monitorModel.test.mjs からも
// 同じロジックを使えるようにするため。ndjson.ts/stepsModel.ts と同じ方針)。
//
// 契約(別エージェント実装中の `ftester api monitor --project <P> [--interval <秒>]
// [--max-width <px>]` の stdout NDJSON):
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
  | { readonly type: "processDown"; readonly message: string };

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
  | { readonly type: "devicesUp" }
  | { readonly type: "devicesDown" }
  | { readonly type: "restartMonitor" };

/** webview からの postMessage 値を MonitorFromWebviewMessage として扱ってよいか判定する。 */
export function isMonitorFromWebviewMessage(value: unknown): value is MonitorFromWebviewMessage {
  if (!isRecord(value) || typeof value.type !== "string") {
    return false;
  }
  return value.type === "devicesUp" || value.type === "devicesDown" || value.type === "restartMonitor";
}
