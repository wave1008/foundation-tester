// retentionModel.ts
// 設定タブ「クリーンアップ」の単位変換・入力検証・CLI 応答の解釈(純粋関数)。
// **vscode 非依存**(webview の settingsTab.js と拡張側 monitorPanel.ts/retentionController.ts の
// 両方が読む。i18n/index.ts は import しない —— webview バンドルが壊れる)。
//
// 契約(CLI 側と並行実装):
//   fleetest api retention                    → {"policy":{…},"defaults":{…},"usage":{…}}
//   fleetest api retention --import '<JSON>'  → 同じ形(渡した鍵だけ上書き・null で既定へ戻す)
//   fleetest api clean [--dry-run]            → 1行 JSON(「消した合計バイト数」と「エラー文字列」
//                                               だけを読む。想定外の鍵は無視する)
// **既定値は CLI が返す defaults だけが正**。拡張側に定数として持たない —— 二重管理にすると
// 片方だけ変わったときに嘘を表示する(FM 枠と同じ規律)。

/** 画面は GB / MB、契約はバイト。**変換はこの2定数と unitFactor 経由の1経路だけ**を通す。 */
export const BYTES_PER_GB = 1024 * 1024 * 1024;
export const BYTES_PER_MB = 1024 * 1024;

export type RetentionUnit = "GB" | "MB";

/** policy/defaults の値。鍵は CLI の JSON と1文字も同じ(kebab 変換をしない)。 */
export type RetentionValues = Readonly<Record<string, number | boolean>>;
/** usage の値(バイト)。 */
export type RetentionUsage = Readonly<Record<string, number>>;
/** setRetention で送る差分。null = その鍵を既定へ戻す。 */
export type RetentionPatch = Readonly<Record<string, number | boolean | null>>;

export interface RetentionField {
  /** policy/defaults の鍵 */
  readonly key: string;
  /** usage の鍵(上限とは別の名前) */
  readonly usageKey: string;
  readonly unit: RetentionUnit;
}

/** 上限4欄。**この順に画面へ並べる**(HTML の id は settingsTab.js の CLEANUP_INPUT_IDS と対)。 */
export const RETENTION_FIELDS: readonly RetentionField[] = [
  { key: "deviceCapturesMaxBytes", usageKey: "deviceCaptures", unit: "GB" },
  { key: "recordingsMaxBytes", usageKey: "recordings", unit: "GB" },
  { key: "reportsMaxBytes", usageKey: "reports", unit: "MB" },
  { key: "logsMaxBytes", usageKey: "logs", unit: "MB" },
];

/** 上限ではない真偽値の鍵(run 完了後に背景で掃除するか。発動は上限の 90% 超)。 */
export const RETENTION_SWEEP_KEY = "sweepAfterRun";

function unitFactor(unit: RetentionUnit): number {
  return unit === "GB" ? BYTES_PER_GB : BYTES_PER_MB;
}

/** バイト → 入力欄に入れる数値。整数倍でない値も往復で戻せるよう小数第3位まで残す。 */
export function bytesToUnitValue(bytes: number, unit: RetentionUnit): number {
  return Math.round((bytes / unitFactor(unit)) * 1000) / 1000;
}

/** 入力欄の数値 → バイト(整数)。 */
export function unitValueToBytes(value: number, unit: RetentionUnit): number {
  return Math.round(value * unitFactor(unit));
}

/**
 * 入力欄の生文字列 → 数値。不正(空欄・負・非数)は null。
 * **0 は有効**(「保持しない」の意味)なので弾かない。`parseInt` は使わない ——
 * "2.5" を黙って 2 にすると打った値と違う上限が保存される。
 */
export function parseRetentionInput(raw: string): number | null {
  const text = raw.trim();
  if (text === "") {
    return null;
  }
  const parsed = Number(text);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }
  return parsed;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

/** 使用量の表示("870.2 GB")。単位記号は言語に依らないので i18n を通さない。 */
export function formatBytes(bytes: number, unit: RetentionUnit): string {
  return `${String(round1(bytes / unitFactor(unit)))} ${unit}`;
}

/** 単位を値の大きさで選ぶ形(確認ダイアログ・掃除結果の合計。1GB 未満は MB)。 */
export function formatBytesAuto(bytes: number): string {
  return formatBytes(bytes, bytes >= BYTES_PER_GB ? "GB" : "MB");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asValues(value: unknown): RetentionValues | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  for (const entry of Object.values(value)) {
    if (typeof entry !== "number" && typeof entry !== "boolean") {
      return undefined;
    }
    if (typeof entry === "number" && !Number.isFinite(entry)) {
      return undefined;
    }
  }
  return value as RetentionValues;
}

/** CLI は `--usage` を付けたときだけ実測を返し、付けないときは**鍵ごと null**(集計は実測 21 秒
 * かかるので、設定タブは先に上限だけ出して使用量を後から埋める)。null は「測っていない」で
 * 0 とは別なので、鍵ごと落として `undefined` のままにする。 */
function asUsage(value: unknown): RetentionUsage | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const measured: Record<string, number> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (entry === null) {
      continue;
    }
    if (typeof entry !== "number" || !Number.isFinite(entry)) {
      return undefined;
    }
    measured[key] = entry;
  }
  return measured as RetentionUsage;
}

export interface RetentionResponse {
  readonly policy: RetentionValues;
  readonly defaults: RetentionValues;
  readonly usage: RetentionUsage;
}

/**
 * `api retention` の1行 JSON を読む。**policy と defaults の両方が読めたときだけ成功**
 * (defaults が無いと空欄・不正値の戻り先が無く、画面が既定を知らないまま動く)。
 * usage は欠けていても空として扱う(表示が消えるだけで設定は編集できる)。
 * 知らない鍵は素通しする —— CLI が欄を足しても拡張の更新を待たずに読める。
 */
export function parseRetentionResponse(json: unknown): RetentionResponse | undefined {
  if (!isRecord(json)) {
    return undefined;
  }
  const policy = asValues(json.policy);
  const defaults = asValues(json.defaults);
  if (policy === undefined || defaults === undefined) {
    return undefined;
  }
  return { policy, defaults, usage: asUsage(json.usage) ?? {} };
}

/** `api clean` の結果のうち拡張が読む欄。**他の鍵(dryRun・categories 等)は無視する** ——
 * 表示は「消した合計」と失敗理由だけに依存させ、CLI 側の欄が増えても壊れないようにする。 */
export interface CleanResult {
  readonly freedBytes?: number;
  readonly error?: string;
}

export function parseCleanResult(json: unknown): CleanResult {
  if (!isRecord(json)) {
    return {};
  }
  const freed = json.freedBytes;
  return {
    freedBytes: typeof freed === "number" && Number.isFinite(freed) ? freed : undefined,
    error: typeof json.error === "string" && json.error !== "" ? json.error : undefined,
  };
}

/**
 * setRetention の patch の形。**鍵は上限4つ + sweepAfterRun だけ**を通す(未知の鍵をそのまま
 * CLI へ渡すと、綴り違いが黙って無視されて「打ったのに効かない」になる)。
 * 上限はバイト(0 以上の整数)か null、sweepAfterRun は真偽か null。
 */
export function isRetentionPatch(value: unknown): value is RetentionPatch {
  if (!isRecord(value)) {
    return false;
  }
  const entries = Object.entries(value);
  if (entries.length === 0) {
    return false;
  }
  for (const [key, entry] of entries) {
    if (entry === null) {
      continue;
    }
    if (key === RETENTION_SWEEP_KEY) {
      if (typeof entry !== "boolean") {
        return false;
      }
      continue;
    }
    if (!RETENTION_FIELDS.some((field) => field.key === key)) {
      return false;
    }
    if (typeof entry !== "number" || !Number.isInteger(entry) || entry < 0) {
      return false;
    }
  }
  return true;
}
