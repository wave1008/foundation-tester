// exploreModel.ts
// `ftester api explore` の NDJSON イベント検証・進捗文言組み立て・入力値検証・完了通知文言・
// デバイス選択アイテム組み立て(vscode 非依存)。monitorExploreController.ts から使う。
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

import { t } from "./i18n";
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

export function formatStepProgressMessage(event: ExploreStepEvent): string {
  return `[${event.step}/${event.maxSteps}] ${event.description}`;
}

/** 出力チャネル「ftester」向けの1行(全イベント種を通した共通フォーマッタ)。 */
export function formatExploreLogLine(event: ExploreEvent): string {
  switch (event.kind) {
    case "exploreStarted":
      return t("exploreHeal.explore.log.started", {
        bundleID: event.bundleID,
        goal: event.goal,
        maxSteps: String(event.maxSteps),
        platform: event.platform,
      });
    case "exploreStep":
      return `[explore] ${formatStepProgressMessage(event)}`;
    case "exploreValidating":
      return `[explore] ${event.message}`;
    case "exploreFinished": {
      const filePart = event.file ? ` file=${event.file}` : "";
      const detailPart = event.detail ? ` detail=${event.detail}` : "";
      return t("exploreHeal.explore.log.finished", {
        outcome: event.outcome,
        stepsTaken: String(event.stepsTaken),
        quarantined: String(event.quarantined),
        filePart,
        detailPart,
      });
    }
    case "error":
      return t("exploreHeal.explore.log.error", { message: event.message });
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
      message: t("exploreHeal.explore.notif.quarantined"),
    };
  }
  switch (event.outcome) {
    case "completed":
      return {
        severity: "info",
        message: t("exploreHeal.explore.notif.completed", { steps: String(event.stepsTaken) }),
      };
    case "gaveUp":
    case "stepLimitReached":
      return {
        severity: "warning",
        message: t("exploreHeal.explore.notif.incomplete"),
      };
  }
}

// ---- 入力値検証(showInputBox の validateInput 用) --------------------------------------
// undefined を返すと妥当な入力として扱われる。文字列を返すと showInputBox 上にエラーとして表示される。

export function validateBundleIdInput(value: string): string | undefined {
  return value.trim().length === 0 ? t("exploreHeal.explore.validate.bundleIdRequired") : undefined;
}

export function validateGoalInput(value: string): string | undefined {
  return value.trim().length === 0 ? t("exploreHeal.explore.validate.goalRequired") : undefined;
}

const MIN_MAX_STEPS = 1;
const MAX_MAX_STEPS = 50;
export const DEFAULT_MAX_STEPS = 25;

function maxStepsRangeMessage(): string {
  return t("exploreHeal.explore.validate.maxStepsRange", {
    min: String(MIN_MAX_STEPS),
    max: String(MAX_MAX_STEPS),
  });
}

export function validateMaxStepsInput(value: string): string | undefined {
  const trimmed = value.trim();
  if (trimmed.length === 0 || !/^\d+$/.test(trimmed)) {
    return maxStepsRangeMessage();
  }
  const parsed = Number(trimmed);
  if (parsed < MIN_MAX_STEPS || parsed > MAX_MAX_STEPS) {
    return maxStepsRangeMessage();
  }
  return undefined;
}

/** validateMaxStepsInput で妥当と確認済みの文字列を整数に変換する。 */
export function parseMaxSteps(value: string): number {
  return Number(value.trim());
}

// ---- デバイス選択 QuickPick アイテム組み立て -------------------------------------------

// locale が activate() 時に確定する(モジュール評価時点は未確定)ため、モジュール定数ではなく
// 呼び出し時に t() を引く関数にする(healReviewPanel.ts の旧 PANEL_TITLE と同じ罠)。
function deviceStateLabel(state: LiveDeviceOptionState): string {
  switch (state) {
    case "connected":
      return t("exploreHeal.explore.deviceState.connected");
    case "booted":
      return t("exploreHeal.explore.deviceState.booted");
    case "offline":
      return t("exploreHeal.explore.deviceState.offline");
    case "unknown":
      return t("exploreHeal.explore.deviceState.unknown");
  }
}

export interface ExploreDeviceQuickPickItem {
  readonly label: string;
  readonly description: string;
  readonly detail: string | undefined;
  readonly device: LiveDeviceOption;
}

/** 探索はデバイスへの実操作を伴うため、connected 以外のデバイスには detail に注意書きを付ける。 */
export function buildDeviceQuickPickItems(
  devices: readonly LiveDeviceOption[],
): ExploreDeviceQuickPickItem[] {
  return devices.map((device) => ({
    label: device.name,
    description: t("exploreHeal.explore.device.description", {
      platform: device.platform,
      state: deviceStateLabel(device.state),
    }),
    detail:
      device.state === "connected" ? undefined : t("exploreHeal.explore.deviceNotConnectedWarning"),
    device,
  }));
}

// ---- モニターパネル「FM探索」タブ webview プロトコル ------------------------------------
// モニターパネル(monitorPanel.ts)は1つのwebviewに複数機能のメッセージが行き交うため、explore系は
// type:"explore" で包んで monitor/live 系メッセージ型との衝突を避ける(liveModel.ts の
// LiveWebviewEnvelope と同じ方式)。対向: src/webview/monitor/exploreTab.js、処理:
// src/monitorExploreController.ts

export type ExploreFromWebviewMessage =
  | { readonly type: "refreshDevices" }
  | { readonly type: "selectDevice"; readonly id: string }
  | { readonly type: "start"; readonly bundleId: string; readonly goal: string; readonly maxSteps: string }
  | { readonly type: "cancel" }
  | { readonly type: "openFile" };

function isExploreFromWebviewMessage(value: unknown): value is ExploreFromWebviewMessage {
  if (!isRecord(value) || typeof value.type !== "string") {
    return false;
  }
  switch (value.type) {
    case "refreshDevices":
    case "cancel":
    case "openFile":
      return true;
    case "selectDevice":
      return typeof value.id === "string";
    case "start":
      return (
        typeof value.bundleId === "string" && typeof value.goal === "string" && typeof value.maxSteps === "string"
      );
    default:
      return false;
  }
}

export type ExploreResultSeverity = "info" | "warning" | "error";

/** "result"/"hydrate" の完了通知表示(hasFile は「ファイルを開く」ボタンの表示要否)。 */
export interface ExploreResultView {
  readonly message: string;
  readonly severity: ExploreResultSeverity;
  readonly hasFile: boolean;
}

export type ExploreToWebviewMessage =
  | { readonly type: "devices"; readonly devices: readonly LiveDeviceOption[]; readonly selectedId: string | undefined }
  | { readonly type: "banner"; readonly message: string | null }
  | { readonly type: "formError"; readonly message: string | null }
  | { readonly type: "running"; readonly running: boolean }
  | { readonly type: "log"; readonly line: string }
  | ({ readonly type: "result" } & ExploreResultView)
  | {
      readonly type: "hydrate";
      readonly running: boolean;
      readonly logLines: readonly string[];
      readonly lastBundleId: string;
      readonly result: ExploreResultView | null;
      readonly devices: readonly LiveDeviceOption[];
      readonly selectedId: string | undefined;
    };

/** webview → host。 */
export interface ExploreWebviewEnvelope {
  readonly type: "explore";
  readonly message: ExploreFromWebviewMessage;
}

export function isExploreWebviewEnvelope(value: unknown): value is ExploreWebviewEnvelope {
  return isRecord(value) && value.type === "explore" && isExploreFromWebviewMessage(value.message);
}

/** host → webview。 */
export interface ExploreToWebviewEnvelope {
  readonly type: "explore";
  readonly message: ExploreToWebviewMessage;
}
