// dashboardModel.ts
// 結果ダッシュボードパネル(dashboardPanel.ts)の vscode 非依存の型・ペイロード型ガード。
//
// 契約(Sources/ftester/ApiResultsCommand.swift): `ftester api results --project <名> --since 90d
// --min-runs 3` の stdout は下記形状の 1 行 JSON(schemaVersion=1)。Swift 側は Codable の nil
// Optional をキー省略でエンコードするため、値が無いフィールドは undefined(null ではない)で
// 届く想定だが、型ガードは null も許容し双方に耐える。

export interface RunMetaRecord {
  readonly schemaVersion: number;
  readonly runID: string;
  readonly project: string;
  readonly profile?: string | null;
  readonly machine: string;
  /** "api" | "cli" */
  readonly trigger: string;
  readonly startedAt: string;
  readonly finishedAt?: string | null;
  readonly total?: number | null;
  readonly passed?: number | null;
  readonly failed?: number | null;
  /** 実行中に劣化・離脱したワーカー(「label: 理由」)。Swift 側 RunMetaRecord.degradedWorkers と対。
   * 空/未発生は省略(nil)。連鎖失敗の事後診断用(現状はダッシュボード未表示・run.json に永続化のみ)。 */
  readonly degradedWorkers?: readonly string[] | null;
  /** 凍結等による結果取り消し+振り直しの監査記録。Swift 側 RunMetaRecord.freezeRetries と対
   * (成功した振り直しはシナリオ記録に痕跡を残さないため、ここが唯一の証跡)。 */
  readonly freezeRetries?: readonly string[] | null;
}

export interface ScenarioSummaryRow {
  readonly scenarioID: string;
  readonly runs: number;
  /** 0-100 */
  readonly successRate: number;
  readonly avgDurationMs?: number | null;
  readonly medianDurationMs?: number | null;
  readonly lastRunAt?: string | null;
  readonly lastPassed?: boolean | null;
}

export interface FlakyRow {
  readonly scenarioID: string;
  readonly runs: number;
  /** 0-100 */
  readonly failureRate: number;
  readonly flakinessScore: number;
  /** 新しい順、最大10件 */
  readonly recentResults: readonly boolean[];
}

export interface DeviceWorkerRow {
  readonly worker: string;
  readonly runs: number;
  readonly successRate: number;
  readonly avgDurationMs?: number | null;
}

export interface DevicePlatformRow {
  readonly platform: string;
  readonly runs: number;
  readonly successRate: number;
  readonly avgDurationMs?: number | null;
}

export interface DeviceSummary {
  readonly byWorker: readonly DeviceWorkerRow[];
  readonly byPlatform: readonly DevicePlatformRow[];
}

export interface DailyRow {
  readonly date: string; // "yyyy-MM-dd"
  readonly total: number;
  readonly passed: number;
  readonly failed: number;
}

export interface SceneResultRecord {
  readonly scene: number;
  readonly title: string;
  readonly passed: boolean;
  readonly durationMs?: number | null;
}

export interface StepCountsRecord {
  readonly total: number;
  readonly passed: number;
  readonly failed: number;
  readonly skipped: number;
  readonly healed: number;
  readonly passedViaFallback: number;
}

/** --scenario 指定時の trend にのみ現れる(ダッシュボードの表示優先度には含まれない)。 */
export interface ScenarioRunRecord {
  readonly runID: string;
  readonly scenarioID: string;
  readonly title?: string | null;
  readonly platform: string;
  readonly worker?: string | null;
  readonly machine: string;
  readonly profile?: string | null;
  readonly passed: boolean;
  readonly timedOut?: boolean | null;
  readonly startedAt: string;
  readonly durationMs: number;
  readonly scenes: readonly SceneResultRecord[];
  readonly steps: StepCountsRecord;
  readonly reportPath?: string | null;
}

export interface SlowScenarioRow {
  readonly scenarioID: string;
  readonly runs: number;
  readonly avgDurationMs: number;
  readonly p90DurationMs: number;
  /** 前半→後半の平均変化率%。4回未満はキー欠落。 */
  readonly deltaPct?: number | null;
  /** 最も遅い scene のタイトル。無ければキー欠落(slowestSceneAvgMs も同様)。 */
  readonly slowestScene?: string | null;
  readonly slowestSceneAvgMs?: number | null;
}

export type InsightKind =
  | "newFailure"
  | "consecutiveFailures"
  | "infraFailures"
  | "selectorDecay"
  | "deviceBias"
  | "durationRegression"
  | "unfinishedRuns";

export type InsightSeverity = "critical" | "warn" | "info";

export interface InsightRecord {
  readonly kind: InsightKind;
  readonly severity: InsightSeverity;
  readonly scenarioID?: string | null;
  /** deviceBias のみ */
  readonly worker?: string | null;
  readonly message: string;
  readonly count?: number | null;
  /** durationRegression のみ */
  readonly deltaPct?: number | null;
}

export interface ApiResultsPayload {
  readonly schemaVersion: number;
  readonly project: string;
  readonly generatedAt: string;
  readonly since: string;
  /** runID 降順、最大50件 */
  readonly runs: readonly RunMetaRecord[];
  /** 成功率昇順 */
  readonly summary: readonly ScenarioSummaryRow[];
  /** 不安定度降順 */
  readonly flaky: readonly FlakyRow[];
  readonly devices: DeviceSummary;
  /** date 昇順 */
  readonly daily: readonly DailyRow[];
  readonly trend?: readonly ScenarioRunRecord[];
  /** avgDurationMs 降順、最大10件。本フィールド追加前の CLI ではキー欠落(古い CLI との互換で必須にしない)。 */
  readonly slow?: readonly SlowScenarioRow[];
  /** severity 順(critical→warn→info)。本フィールド追加前の CLI ではキー欠落。 */
  readonly insights?: readonly InsightRecord[];
}

// ---- webview ⇔ 拡張のメッセージ契約 ----------------------------------------------------
// 対向: src/webview/dashboard/main.js のメッセージハンドラ(手書き複製ではなくそのまま参照する
// 契約なので、フィールドを増減したら両方直すこと)。

export type DashboardFromWebviewMessage = { readonly type: "ready" } | { readonly type: "refresh" };

export type DashboardToWebviewMessage =
  | { readonly type: "loading" }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "data"; readonly payload: ApiResultsPayload };

// ---- 型ガード ---------------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isOptString(value: unknown): value is string | undefined | null {
  return value === undefined || value === null || typeof value === "string";
}

function isOptNumber(value: unknown): value is number | undefined | null {
  return value === undefined || value === null || typeof value === "number";
}

function isOptBoolean(value: unknown): value is boolean | undefined | null {
  return value === undefined || value === null || typeof value === "boolean";
}

function isRunMetaRecord(value: unknown): value is RunMetaRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.schemaVersion === "number" &&
    typeof value.runID === "string" &&
    typeof value.project === "string" &&
    isOptString(value.profile) &&
    typeof value.machine === "string" &&
    typeof value.trigger === "string" &&
    typeof value.startedAt === "string" &&
    isOptString(value.finishedAt) &&
    isOptNumber(value.total) &&
    isOptNumber(value.passed) &&
    isOptNumber(value.failed)
  );
}

function isScenarioSummaryRow(value: unknown): value is ScenarioSummaryRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.scenarioID === "string" &&
    typeof value.runs === "number" &&
    typeof value.successRate === "number" &&
    isOptNumber(value.avgDurationMs) &&
    isOptNumber(value.medianDurationMs) &&
    isOptString(value.lastRunAt) &&
    isOptBoolean(value.lastPassed)
  );
}

function isFlakyRow(value: unknown): value is FlakyRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.scenarioID === "string" &&
    typeof value.runs === "number" &&
    typeof value.failureRate === "number" &&
    typeof value.flakinessScore === "number" &&
    Array.isArray(value.recentResults) &&
    value.recentResults.every((r) => typeof r === "boolean")
  );
}

function isDeviceWorkerRow(value: unknown): value is DeviceWorkerRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.worker === "string" &&
    typeof value.runs === "number" &&
    typeof value.successRate === "number" &&
    isOptNumber(value.avgDurationMs)
  );
}

function isDevicePlatformRow(value: unknown): value is DevicePlatformRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.platform === "string" &&
    typeof value.runs === "number" &&
    typeof value.successRate === "number" &&
    isOptNumber(value.avgDurationMs)
  );
}

function isDeviceSummary(value: unknown): value is DeviceSummary {
  if (!isRecord(value)) return false;
  return (
    Array.isArray(value.byWorker) &&
    value.byWorker.every(isDeviceWorkerRow) &&
    Array.isArray(value.byPlatform) &&
    value.byPlatform.every(isDevicePlatformRow)
  );
}

function isDailyRow(value: unknown): value is DailyRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.date === "string" &&
    typeof value.total === "number" &&
    typeof value.passed === "number" &&
    typeof value.failed === "number"
  );
}

function isSlowScenarioRow(value: unknown): value is SlowScenarioRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.scenarioID === "string" &&
    typeof value.runs === "number" &&
    typeof value.avgDurationMs === "number" &&
    typeof value.p90DurationMs === "number" &&
    isOptNumber(value.deltaPct) &&
    isOptString(value.slowestScene) &&
    isOptNumber(value.slowestSceneAvgMs)
  );
}

function isInsightKind(value: unknown): value is InsightKind {
  return (
    value === "newFailure" ||
    value === "consecutiveFailures" ||
    value === "infraFailures" ||
    value === "selectorDecay" ||
    value === "deviceBias" ||
    value === "durationRegression" ||
    value === "unfinishedRuns"
  );
}

function isInsightSeverity(value: unknown): value is InsightSeverity {
  return value === "critical" || value === "warn" || value === "info";
}

function isInsightRecord(value: unknown): value is InsightRecord {
  if (!isRecord(value)) return false;
  return (
    isInsightKind(value.kind) &&
    isInsightSeverity(value.severity) &&
    isOptString(value.scenarioID) &&
    isOptString(value.worker) &&
    typeof value.message === "string" &&
    isOptNumber(value.count) &&
    isOptNumber(value.deltaPct)
  );
}

/** ApiResultsCommand の stdout(JSON.parse 済みの unknown)を検証する。 */
export function isApiResultsPayload(value: unknown): value is ApiResultsPayload {
  if (!isRecord(value)) return false;
  if (
    typeof value.schemaVersion !== "number" ||
    typeof value.project !== "string" ||
    typeof value.generatedAt !== "string" ||
    typeof value.since !== "string"
  ) {
    return false;
  }
  if (!Array.isArray(value.runs) || !value.runs.every(isRunMetaRecord)) return false;
  if (!Array.isArray(value.summary) || !value.summary.every(isScenarioSummaryRow)) return false;
  if (!Array.isArray(value.flaky) || !value.flaky.every(isFlakyRow)) return false;
  if (!isDeviceSummary(value.devices)) return false;
  if (!Array.isArray(value.daily) || !value.daily.every(isDailyRow)) return false;
  // slow/insights はキー欠落(古い CLI)を許容するため undefined のみ特別扱いする。
  if (value.slow !== undefined && (!Array.isArray(value.slow) || !value.slow.every(isSlowScenarioRow))) {
    return false;
  }
  if (value.insights !== undefined && (!Array.isArray(value.insights) || !value.insights.every(isInsightRecord))) {
    return false;
  }
  return true;
}

export function isDashboardFromWebviewMessage(value: unknown): value is DashboardFromWebviewMessage {
  if (!isRecord(value)) return false;
  return value.type === "ready" || value.type === "refresh";
}
