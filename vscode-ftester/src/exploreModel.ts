// exploreModel.ts
// `ftester api explore` の NDJSON イベント検証・進捗文言組み立て・入力値検証・完了通知文言・
// デバイス選択 QuickPick アイテム組み立て(vscode 非依存)。ftester.explore コマンド
// (src/exploreCommand.ts)から使う。monitorModel.ts/liveModel.ts と同じ方針で、
// ロジックをここに切り出すことで test/exploreModel.test.mjs から vscode 無しで検証できる。
//
// 契約(Sources/ftester/ApiExploreCommand.swift):
//   {"kind":"exploreStarted","project","bundleID","goal","maxSteps","platform"}
//   {"kind":"exploreStep","step":n,"maxSteps":N,"description":"..."}     … 1ステップ数十秒かかりうる
//   {"kind":"exploreValidating","message":"..."}
//   {"kind":"exploreFinished","outcome":"completed"|"gaveUp"|"stepLimitReached",
//     "detail":string|null,"stepsTaken":n,"file":"<生成.swiftの絶対パス>"|null,
//     "scenarioID":string|null,"quarantined":bool}
//     … quarantined=true はビルド検証失敗で Scenarios/_disabled/ に隔離されたことを示す(exit 0)
//   {"kind":"error","message":"..."}                                   … 致命的な失敗(exit 1)

import type { LiveDeviceOption, LiveDeviceOptionState } from "./liveModel";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// ---- NDJSON イベント -----------------------------------------------------------------

export interface ExploreStartedEvent {
  readonly kind: "exploreStarted";
  readonly project: string;
  readonly bundleID: string;
  readonly goal: string;
  readonly maxSteps: number;
  readonly platform: string;
}

export interface ExploreStepEvent {
  readonly kind: "exploreStep";
  readonly step: number;
  readonly maxSteps: number;
  readonly description: string;
}

export interface ExploreValidatingEvent {
  readonly kind: "exploreValidating";
  readonly message: string;
}

export type ExploreOutcome = "completed" | "gaveUp" | "stepLimitReached";
const OUTCOMES: ReadonlySet<string> = new Set<ExploreOutcome>(["completed", "gaveUp", "stepLimitReached"]);

export interface ExploreFinishedEvent {
  readonly kind: "exploreFinished";
  readonly outcome: ExploreOutcome;
  readonly detail: string | null;
  readonly stepsTaken: number;
  readonly file: string | null;
  readonly scenarioID: string | null;
  readonly quarantined: boolean;
}

export interface ExploreErrorEvent {
  readonly kind: "error";
  readonly message: string;
}

export type ExploreEvent =
  | ExploreStartedEvent
  | ExploreStepEvent
  | ExploreValidatingEvent
  | ExploreFinishedEvent
  | ExploreErrorEvent;

/**
 * value が ExploreEvent として扱ってよいか判定する。既知の kind 以外(将来の追加や壊れた行)や
 * 必須フィールドの欠落・型不一致は false を返すので、呼び出し側は安全に無視できる
 * (monitorModel.isMonitorEvent と同じ方針)。
 */
export function isExploreEvent(value: unknown): value is ExploreEvent {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  switch (value.kind) {
    case "exploreStarted":
      return (
        typeof value.project === "string" &&
        typeof value.bundleID === "string" &&
        typeof value.goal === "string" &&
        typeof value.maxSteps === "number" &&
        typeof value.platform === "string"
      );
    case "exploreStep":
      return (
        typeof value.step === "number" &&
        typeof value.maxSteps === "number" &&
        typeof value.description === "string"
      );
    case "exploreValidating":
      return typeof value.message === "string";
    case "exploreFinished":
      return (
        typeof value.outcome === "string" &&
        OUTCOMES.has(value.outcome) &&
        (value.detail === null || typeof value.detail === "string") &&
        typeof value.stepsTaken === "number" &&
        (value.file === null || typeof value.file === "string") &&
        (value.scenarioID === null || typeof value.scenarioID === "string") &&
        typeof value.quarantined === "boolean"
      );
    case "error":
      return typeof value.message === "string";
    default:
      return false;
  }
}

// ---- 進捗文言組み立て -----------------------------------------------------------------

/** exploreStep の Progress.report 用文言(withProgress のメッセージ): "[n/N] description"。 */
export function formatStepProgressMessage(event: ExploreStepEvent): string {
  return `[${event.step}/${event.maxSteps}] ${event.description}`;
}

/** 出力チャネル「ftester」向けの1行(全イベント種を通した共通フォーマッタ)。 */
export function formatExploreLogLine(event: ExploreEvent): string {
  switch (event.kind) {
    case "exploreStarted":
      return (
        `[explore] 開始: bundle=${event.bundleID} goal=${event.goal} ` +
        `maxSteps=${event.maxSteps} platform=${event.platform}`
      );
    case "exploreStep":
      return `[explore] ${formatStepProgressMessage(event)}`;
    case "exploreValidating":
      return `[explore] ${event.message}`;
    case "exploreFinished": {
      const filePart = event.file ? ` file=${event.file}` : "";
      const detailPart = event.detail ? ` detail=${event.detail}` : "";
      return (
        `[explore] 終了: outcome=${event.outcome} stepsTaken=${event.stepsTaken} ` +
        `quarantined=${String(event.quarantined)}${filePart}${detailPart}`
      );
    }
    case "error":
      return `[explore] エラー: ${event.message}`;
  }
}

// ---- 完了通知文言 ---------------------------------------------------------------------

export interface ExploreFinishedNotification {
  readonly severity: "info" | "warning";
  readonly message: string;
}

/**
 * exploreFinished の通知文言を組み立てる。quarantined(ビルド検証失敗による隔離)は outcome に
 * 関わらず最も注意喚起すべき事実なので、outcome 別の文言より優先して表示する。
 */
export function buildFinishedNotification(event: ExploreFinishedEvent): ExploreFinishedNotification {
  if (event.quarantined) {
    return {
      severity: "warning",
      message: "ftester: ビルド検証に失敗したため _disabled/ に隔離されました。",
    };
  }
  switch (event.outcome) {
    case "completed":
      return { severity: "info", message: `ftester: 探索完了(${event.stepsTaken}ステップ)` };
    case "gaveUp":
    case "stepLimitReached":
      return {
        severity: "warning",
        message: "ftester: 探索は未完了ですがシナリオを生成しました(TODOコメント付き)。",
      };
  }
}

// ---- 入力値検証(showInputBox の validateInput 用) --------------------------------------
// undefined を返すと妥当な入力として扱われる。文字列を返すと showInputBox 上にエラーとして表示される。

export function validateBundleIdInput(value: string): string | undefined {
  return value.trim().length === 0 ? "bundle ID / パッケージ名を入力してください。" : undefined;
}

export function validateGoalInput(value: string): string | undefined {
  return value.trim().length === 0 ? "テストの目標を入力してください。" : undefined;
}

const MIN_MAX_STEPS = 1;
const MAX_MAX_STEPS = 50;
export const DEFAULT_MAX_STEPS = 25;

export function validateMaxStepsInput(value: string): string | undefined {
  const trimmed = value.trim();
  if (trimmed.length === 0 || !/^\d+$/.test(trimmed)) {
    return `${MIN_MAX_STEPS}〜${MAX_MAX_STEPS}の整数を入力してください。`;
  }
  const parsed = Number(trimmed);
  if (parsed < MIN_MAX_STEPS || parsed > MAX_MAX_STEPS) {
    return `${MIN_MAX_STEPS}〜${MAX_MAX_STEPS}の整数を入力してください。`;
  }
  return undefined;
}

/** validateMaxStepsInput で妥当と確認済みの文字列を整数に変換する。 */
export function parseMaxSteps(value: string): number {
  return Number(value.trim());
}

// ---- デバイス選択 QuickPick アイテム組み立て -------------------------------------------

const DEVICE_STATE_LABEL: Record<LiveDeviceOptionState, string> = {
  connected: "接続済み",
  booted: "起動中",
  offline: "未起動",
  unknown: "状態不明(未確認)",
};

export interface ExploreDeviceQuickPickItem {
  readonly label: string;
  readonly description: string;
  readonly detail: string | undefined;
  readonly device: LiveDeviceOption;
}

/**
 * `api list-devices` の結果を QuickPick 用アイテムに変換する。探索はデバイスへの実操作を
 * 伴うため、connected 以外のデバイスには detail に注意書きを付ける。
 */
export function buildDeviceQuickPickItems(
  devices: readonly LiveDeviceOption[],
): ExploreDeviceQuickPickItem[] {
  return devices.map((device) => ({
    label: device.name,
    description: `${device.platform} ・ ${DEVICE_STATE_LABEL[device.state]}`,
    detail:
      device.state === "connected"
        ? undefined
        : "⚠ 接続されていません。探索が失敗する可能性があります。",
    device,
  }));
}
