// dashboardModel.ts
// 結果ダッシュボード(モニターパネル「ダッシュボード」タブ、旧・単独パネル dashboardPanel.ts)の
// vscode 非依存の型・ペイロード型ガード。ホスト側の実体は monitorDashboardController.ts。
//
// 契約(Sources/fleetest/ApiResultsCommand.swift): `fleetest api results --project <名> --since 90d
// --min-runs 3` の stdout は下記形状の 1 行 JSON(schemaVersion=1)。Swift 側は Codable の nil
// Optional をキー省略でエンコードするため、値が無いフィールドは undefined(null ではない)で
// 届く想定だが、型ガードは null も許容し双方に耐える。

export interface RunMetaRecord {
  readonly schemaVersion: number;
  readonly runID: string;
  readonly project: string;
  readonly profile?: string | null;
  /** その run を走らせた**機械のホスト名**(旧キー "machine" も読む。2026-08-26 改名。
   * 用語: host = ホスト名/IP、machine = そのローカルエイリアス)。 */
  readonly host: string;
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
  /** run 前の blank 判定で sleep/wake 修復により除外を免れたワーカー label。
   * Swift 側 RunMetaRecord.blankRepairs と対(現状はダッシュボード未表示・run.json 永続化のみ)。 */
  readonly blankRepairs?: readonly string[] | null;
  /** run 前の blank 判定で修復不発により除外したワーカー label(guest reboot 発行済み)。
   * Swift 側 RunMetaRecord.blankExclusions と対。 */
  readonly blankExclusions?: readonly string[] | null;
  /** degradedWorkers / freezeRetries と**同じ事象**の構造化版(Swift 側 RunMetaRecord.workerAnomalies)。
   * worker は "<platform>:<デバイス論理名>" で ScenarioRunRecord.worker と join できる。
   * 現状はダッシュボード未表示・run.json 永続化のみ(スキーマは docs/results-json.md)。 */
  readonly workerAnomalies?: readonly {
    readonly kind: string;
    readonly worker?: string | null;
    readonly label: string;
    readonly scenarioID?: string | null;
    readonly reason: string;
  }[] | null;
  /** performanceMode の run で、実行中にレーン数が変わり所要時間が計測に使えないときだけ true
   * (Swift 側 RunRecord.measurementInvalid と対)。 */
  readonly measurementInvalid?: boolean | null;
  /** measurementInvalid=true のときの理由(英語)。 */
  readonly measurementInvalidReasons?: readonly string[] | null;
  /** 同じ実行(ファンアウト)から分かれた run を束ねる鍵。単機の run と旧い記録では欠落。 */
  readonly runGroup?: string | null;
  /** `--performance` 付きで走った run か(Swift 側 RunMetaRecord.performanceMode と対)。
   * 本フィールド追加前の CLI ではキー欠落。 */
  readonly performanceMode?: boolean | null;
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
  /** 後発フィールド。旧レコードには無いので optional。 */
  readonly inconclusive?: number;
}

/** run 詳細(`fleetest api results-run`)の失敗ステップ1件。docs/results-json.md の
 * FailedStepRecord と対。 */
export interface FailedStepRecord {
  readonly index: number;
  readonly scene?: number | null;
  readonly sceneTitle?: string | null;
  /** "condition" / "action" / "expectation" / "setUp" / "tearDown"。ブロック外は無し。 */
  readonly section?: string | null;
  readonly description: string;
  /** DSL のコマンド名。description を割って作らないこと。 */
  readonly command?: string | null;
  readonly failureKind?: string | null;
  readonly notes?: readonly string[] | null;
  /** 失敗理由(英語・人間可読)。 */
  readonly detail?: string | null;
  readonly file?: string | null;
  readonly line?: number | null;
  readonly durationMs?: number | null;
  readonly at?: string | null;
}

/** セレクタの修正提案。成否によらず残る(docs/results-json.md の FixSuggestionRecord と対)。 */
export interface FixSuggestionRecord {
  readonly scene?: number | null;
  readonly file?: string | null;
  readonly line?: number | null;
  readonly oldSelector?: string | null;
  readonly newSelector?: string | null;
}

/** --scenario 指定時の trend、および run 詳細(results-run)の scenarios[] に現れる。 */
export interface ScenarioRunRecord {
  readonly runID: string;
  readonly scenarioID: string;
  readonly title?: string | null;
  readonly platform: string;
  readonly worker?: string | null;
  /** 機械のホスト名(RunMetaRecord.host と同じ。旧キー "machine" も読む)。 */
  readonly host: string;
  readonly profile?: string | null;
  readonly passed: boolean;
  readonly timedOut?: boolean | null;
  readonly startedAt: string;
  readonly durationMs: number;
  readonly scenes: readonly SceneResultRecord[];
  readonly steps: StepCountsRecord;
  readonly reportPath?: string | null;
  /** 失敗時のみ。ステップに到達しないまま落ちた run では空(errorLogs/skipKind が一次情報)。 */
  readonly failedSteps?: readonly FailedStepRecord[] | null;
  /** ❌/⚠️/⏱ で始まるログの末尾5件。失敗時のみ。 */
  readonly errorLogs?: readonly string[] | null;
  /** "notApplicable"(対象プラットフォーム外)/ "noWorker"(ワーカー不在等の事故)。 */
  readonly skipKind?: string | null;
  readonly fixSuggestions?: readonly FixSuggestionRecord[] | null;
  /** 録画再生 UI 向け。ダッシュボードの表示には使わない(Array であることだけ検証)。 */
  readonly timeline?: readonly unknown[] | null;
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
  | "unfinishedRuns"
  | "unsettledSteps"
  | "retiredScenarios"
  | "healReliance";

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

export interface MatrixRunColumn {
  readonly runID: string;
  readonly startedAt: string;
  readonly profile?: string | null;
}

export interface MatrixScenarioRow {
  readonly scenarioID: string;
  readonly title?: string | null;
  /** runs と同順・同数。1=passed 0=failed null=その run にこのシナリオの記録が無い */
  readonly cells: readonly (number | null)[];
}

export interface MatrixReport {
  /** newest-first(startedAt 降順) */
  readonly runs: readonly MatrixRunColumn[];
  /** flaky(pass/fail混在)→ all-fail → all-pass、各グループ内は scenarioID 昇順 */
  readonly scenarios: readonly MatrixScenarioRow[];
}

/** count 降順。section/command/failureKind は言えないとき欄ごと省く(「その他」に丸めない)。
 * failureKind/command の欄が無い失敗は 2026-08-20 より前の記録に必ずある(欄の後発追加)ので、
 * 必須にすると実データでペイロード全体が弾かれる。 */
export interface TriageRow {
  readonly section?: string | null;
  readonly command?: string | null;
  readonly failureKind?: string | null;
  readonly count: number;
  readonly scenarioCount: number;
  /** 最大5件。 */
  readonly scenarioIDs: readonly string[];
}

export interface TriageNoteCount {
  readonly note: string;
  readonly count: number;
}

/** `fleetest api results` の失敗の仕分け(窓内の失敗シナリオレコードの集計)。 */
export interface TriageReport {
  readonly totalFailed: number;
  /** うち failedSteps 無し(ステップ未到達)。 */
  readonly unreachedCount: number;
  /** count 降順。 */
  readonly rows: readonly TriageRow[];
  /** count 降順。 */
  readonly noteCounts: readonly TriageNoteCount[];
}

/** `--performance` run 1本(`fleetest api results` の performance.runs[])。 */
export interface PerfRunRow {
  /** グループ鍵(フリート計測は runGroup で1行に畳まれる。単機 run はその runID)。 */
  readonly runID: string;
  /** 畳んだ run の全 runID。本フィールド追加前の CLI ではキー省略あり。 */
  readonly runIDs?: readonly string[] | null;
  readonly startedAt: string;
  readonly profile?: string | null;
  readonly host: string;
  /** グループ内の全機械のホスト名(昇順)。表示は machine へ読み替える。キー省略あり(旧 CLI)。 */
  readonly hosts?: readonly string[] | null;
  /** run の壁時計(グループ最初の開始〜最後の完了)。未完了等でキー省略あり。 */
  readonly wallClockMs?: number | null;
  /** テスト時間(最初のシナリオ開始〜最後の完了)。稼働率の分母。キー省略あり。 */
  readonly testTimeMs?: number | null;
  /** シナリオ所要合計。 */
  readonly scenarioTotalMs: number;
  readonly scenarioCount: number;
  readonly passed?: number | null;
  readonly failed?: number | null;
  /** 最長1本(= test time の下限)の所要とその scenarioID。キー省略あり。 */
  readonly maxScenarioMs?: number | null;
  readonly maxScenarioID?: string | null;
  /** レーン数(distinct worker 数)。 */
  readonly laneCount: number;
  /** レーン稼働率(%)。キー省略あり。 */
  readonly avgLaneUtilisationPct?: number | null;
}

/** 最新 run vs 同じ (profile, host) の直前 run のシナリオ単位の所要突き合わせ
 * (`fleetest api results` の performance.comparison[])。悪化が正、降順。 */
export interface PerfScenarioDelta {
  readonly scenarioID: string;
  readonly platform: string;
  readonly latestMs: number;
  readonly previousMs: number;
  readonly deltaPct: number;
}

/** `fleetest api results` の performance キー(--performance run の集計)。 */
export interface PerformanceReport {
  /** 有効な --performance run(新しい順)。空配列あり。 */
  readonly runs: readonly PerfRunRow[];
  /** measurementInvalid で除外した performance run 数。 */
  readonly invalidCount: number;
  /** 空配列あり。 */
  readonly comparison: readonly PerfScenarioDelta[];
  /** 比較相手の runID。無ければキー省略。 */
  readonly comparedRunID?: string | null;
  /** comparison の最新側の runID(runs の先頭と一致するとは限らない)。キー省略あり。 */
  readonly comparisonRunID?: string | null;
}

/** `fleetest api results-run --project <名> --run-id <runID>` の stdout。 */
export interface ApiResultsRunPayload {
  readonly schemaVersion: number;
  readonly project: string;
  readonly run: RunMetaRecord;
  readonly scenarios: readonly ScenarioRunRecord[];
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
  /** シナリオ×直近N run の成否マトリクス。--matrix-runs 0 指定時・本フィールド追加前の CLI ではキー欠落。 */
  readonly matrix?: MatrixReport;
  /** 失敗の仕分け。本フィールド追加前の CLI ではキー欠落。 */
  readonly triage?: TriageReport;
  /** (run.total >= fullSuiteMinScenarios) の run だけで再計算した日次。date 昇順。
   * 本フィールド追加前の CLI ではキー欠落。 */
  readonly dailyFullSuite?: readonly DailyRow[];
  /** dailyFullSuite の閾値(ラベル表示用。ハードコードしない)。本フィールド追加前の CLI ではキー欠落。 */
  readonly fullSuiteMinScenarios?: number;
  /** `--performance` run の集計。本フィールド追加前の CLI ではキー欠落。 */
  readonly performance?: PerformanceReport;
  /** 記録の host(ホスト名)→ この Mac の登録名(machine)の読み替え表(facts キャッシュ由来。
   * 表示時にだけ引く —— 記録・runID は host のまま)。本フィールド追加前の CLI ではキー欠落。 */
  readonly machines?: readonly MachineAliasRow[];
  /** runs と同じ集合の per-run 時間統計。本フィールド追加前の CLI ではキー欠落。 */
  readonly runStats?: readonly RunStatsRow[];
}

/** host(記録の鍵)→ machine(表示名)の1組。Swift 側 ApiResultsCommand.MachineAliasEntry と対。 */
export interface MachineAliasRow {
  readonly host: string;
  readonly machine: string;
}

/** runs と同じ集合の per-run 時間統計(Swift 側 RunResultsQuery.RunStatsRow と対)。
 * 表示側が runGroup 単位に畳むため、テスト時間は端点(testStartedAt/testFinishedAt)も届く。 */
export interface RunStatsRow {
  readonly runID: string;
  readonly wallClockMs?: number | null;
  readonly testStartedAt?: string | null;
  readonly testFinishedAt?: string | null;
  readonly testTimeMs?: number | null;
  readonly scenarioTotalMs: number;
  readonly scenarioCount: number;
  readonly laneCount: number;
  readonly maxScenarioMs?: number | null;
  readonly maxScenarioID?: string | null;
}

// ---- webview ⇔ 拡張のメッセージ契約 ----------------------------------------------------
// 対向: src/webview/monitor/dashboardTab.js のメッセージハンドラ(手書き複製ではなくそのまま参照する
// 契約なので、フィールドを増減したら両方直すこと)。

export type DashboardFromWebviewMessage =
  | { readonly type: "ready" }
  | { readonly type: "refresh" }
  /** runIDs = 同じ実行(runGroup)の構成 run 全部(先頭 = runID)。旧 webview は省略。 */
  | { readonly type: "runDetail"; readonly runID: string; readonly runIDs?: readonly string[] }
  | { readonly type: "trend"; readonly scenarioID: string }
  | { readonly type: "openReport"; readonly path: string }
  | { readonly type: "selectProject"; readonly project: string };

export type DashboardToWebviewMessage =
  | { readonly type: "loading" }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "data"; readonly payload: ApiResultsPayload }
  /** 構成 run ごとの results-run 応答(先頭 = リクエストした primary)。 */
  | { readonly type: "runDetail"; readonly payloads: readonly ApiResultsRunPayload[] }
  | { readonly type: "runDetailError"; readonly runID: string; readonly message: string }
  | { readonly type: "trend"; readonly scenarioID: string; readonly records: readonly ScenarioRunRecord[] }
  | { readonly type: "trendError"; readonly scenarioID: string; readonly message: string }
  /** TestProjects/ 直下の候補と現在の解決結果(未解決なら "")。refresh のたびに送る。 */
  | { readonly type: "projects"; readonly projects: readonly string[]; readonly current: string };

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
    typeof value.host === "string" &&
    typeof value.trigger === "string" &&
    typeof value.startedAt === "string" &&
    isOptString(value.finishedAt) &&
    isOptNumber(value.total) &&
    isOptNumber(value.passed) &&
    isOptNumber(value.failed) &&
    isOptBoolean(value.performanceMode)
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
    value === "unfinishedRuns" ||
    value === "unsettledSteps" ||
    value === "retiredScenarios" ||
    value === "healReliance"
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

function isMatrixRunColumn(value: unknown): value is MatrixRunColumn {
  if (!isRecord(value)) return false;
  return typeof value.runID === "string" && typeof value.startedAt === "string" && isOptString(value.profile);
}

function isMatrixScenarioRow(value: unknown): value is MatrixScenarioRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.scenarioID === "string" &&
    isOptString(value.title) &&
    Array.isArray(value.cells) &&
    value.cells.every((c) => c === null || typeof c === "number")
  );
}

function isMatrixReport(value: unknown): value is MatrixReport {
  if (!isRecord(value)) return false;
  return (
    Array.isArray(value.runs) &&
    value.runs.every(isMatrixRunColumn) &&
    Array.isArray(value.scenarios) &&
    value.scenarios.every(isMatrixScenarioRow)
  );
}

function isOptStringArray(value: unknown): value is readonly string[] | undefined | null {
  return value === undefined || value === null || (Array.isArray(value) && value.every((v) => typeof v === "string"));
}

function isTriageRow(value: unknown): value is TriageRow {
  if (!isRecord(value)) return false;
  return (
    isOptString(value.section) &&
    isOptString(value.command) &&
    isOptString(value.failureKind) &&
    typeof value.count === "number" &&
    typeof value.scenarioCount === "number" &&
    Array.isArray(value.scenarioIDs) &&
    value.scenarioIDs.every((s) => typeof s === "string")
  );
}

function isTriageNoteCount(value: unknown): value is TriageNoteCount {
  if (!isRecord(value)) return false;
  return typeof value.note === "string" && typeof value.count === "number";
}

function isTriageReport(value: unknown): value is TriageReport {
  if (!isRecord(value)) return false;
  return (
    typeof value.totalFailed === "number" &&
    typeof value.unreachedCount === "number" &&
    Array.isArray(value.rows) &&
    value.rows.every(isTriageRow) &&
    Array.isArray(value.noteCounts) &&
    value.noteCounts.every(isTriageNoteCount)
  );
}

function isSceneResultRecord(value: unknown): value is SceneResultRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.scene === "number" &&
    typeof value.title === "string" &&
    typeof value.passed === "boolean" &&
    isOptNumber(value.durationMs)
  );
}

function isStepCountsRecord(value: unknown): value is StepCountsRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.total === "number" &&
    typeof value.passed === "number" &&
    typeof value.failed === "number" &&
    typeof value.skipped === "number" &&
    typeof value.healed === "number" &&
    typeof value.passedViaFallback === "number" &&
    isOptNumber(value.inconclusive)
  );
}

function isFailedStepRecord(value: unknown): value is FailedStepRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.index === "number" &&
    isOptNumber(value.scene) &&
    isOptString(value.sceneTitle) &&
    isOptString(value.section) &&
    typeof value.description === "string" &&
    isOptString(value.command) &&
    isOptString(value.failureKind) &&
    isOptStringArray(value.notes) &&
    isOptString(value.detail) &&
    isOptString(value.file) &&
    isOptNumber(value.line) &&
    isOptNumber(value.durationMs) &&
    isOptString(value.at)
  );
}

function isFixSuggestionRecord(value: unknown): value is FixSuggestionRecord {
  if (!isRecord(value)) return false;
  return (
    isOptNumber(value.scene) &&
    isOptString(value.file) &&
    isOptNumber(value.line) &&
    isOptString(value.oldSelector) &&
    isOptString(value.newSelector)
  );
}

/** trend / run 詳細(results-run)の scenarios[] 双方で使う。 */
function isScenarioRunRecord(value: unknown): value is ScenarioRunRecord {
  if (!isRecord(value)) return false;
  if (
    typeof value.runID !== "string" ||
    typeof value.scenarioID !== "string" ||
    !isOptString(value.title) ||
    typeof value.platform !== "string" ||
    !isOptString(value.worker) ||
    typeof value.host !== "string" ||
    !isOptString(value.profile) ||
    typeof value.passed !== "boolean" ||
    !isOptBoolean(value.timedOut) ||
    typeof value.startedAt !== "string" ||
    typeof value.durationMs !== "number"
  ) {
    return false;
  }
  if (!Array.isArray(value.scenes) || !value.scenes.every(isSceneResultRecord)) return false;
  if (!isStepCountsRecord(value.steps)) return false;
  if (!isOptString(value.reportPath)) return false;
  if (value.failedSteps !== undefined && value.failedSteps !== null) {
    if (!Array.isArray(value.failedSteps) || !value.failedSteps.every(isFailedStepRecord)) return false;
  }
  if (!isOptStringArray(value.errorLogs)) return false;
  if (!isOptString(value.skipKind)) return false;
  if (value.fixSuggestions !== undefined && value.fixSuggestions !== null) {
    if (!Array.isArray(value.fixSuggestions) || !value.fixSuggestions.every(isFixSuggestionRecord)) return false;
  }
  if (value.timeline !== undefined && value.timeline !== null && !Array.isArray(value.timeline)) return false;
  return true;
}

function isPerfRunRow(value: unknown): value is PerfRunRow {
  if (!isRecord(value)) return false;
  return (
    typeof value.runID === "string" &&
    isOptStringArray(value.runIDs) &&
    typeof value.startedAt === "string" &&
    isOptString(value.profile) &&
    typeof value.host === "string" &&
    isOptStringArray(value.hosts) &&
    isOptNumber(value.wallClockMs) &&
    isOptNumber(value.testTimeMs) &&
    typeof value.scenarioTotalMs === "number" &&
    typeof value.scenarioCount === "number" &&
    isOptNumber(value.passed) &&
    isOptNumber(value.failed) &&
    isOptNumber(value.maxScenarioMs) &&
    isOptString(value.maxScenarioID) &&
    typeof value.laneCount === "number" &&
    isOptNumber(value.avgLaneUtilisationPct)
  );
}

function isPerfScenarioDelta(value: unknown): value is PerfScenarioDelta {
  if (!isRecord(value)) return false;
  return (
    typeof value.scenarioID === "string" &&
    typeof value.platform === "string" &&
    typeof value.latestMs === "number" &&
    typeof value.previousMs === "number" &&
    typeof value.deltaPct === "number"
  );
}

function isPerformanceReport(value: unknown): value is PerformanceReport {
  if (!isRecord(value)) return false;
  return (
    Array.isArray(value.runs) &&
    value.runs.every(isPerfRunRow) &&
    typeof value.invalidCount === "number" &&
    Array.isArray(value.comparison) &&
    value.comparison.every(isPerfScenarioDelta) &&
    isOptString(value.comparedRunID) &&
    isOptString(value.comparisonRunID)
  );
}

/** ApiResultsRunCommand(`fleetest api results-run`)の stdout を検証する。 */
export function isApiResultsRunPayload(value: unknown): value is ApiResultsRunPayload {
  if (!isRecord(value)) return false;
  if (typeof value.schemaVersion !== "number" || typeof value.project !== "string") return false;
  if (!isRunMetaRecord(value.run)) return false;
  if (!Array.isArray(value.scenarios) || !value.scenarios.every(isScenarioRunRecord)) return false;
  return true;
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
  // matrix はキー欠落(--matrix-runs 0・古い CLI)を許容するため undefined のみ特別扱いする。
  if (value.matrix !== undefined && !isMatrixReport(value.matrix)) {
    return false;
  }
  // triage/dailyFullSuite/fullSuiteMinScenarios はキー欠落(旧 CLI)を許容するため undefined のみ特別扱いする。
  if (value.triage !== undefined && !isTriageReport(value.triage)) {
    return false;
  }
  if (
    value.dailyFullSuite !== undefined &&
    (!Array.isArray(value.dailyFullSuite) || !value.dailyFullSuite.every(isDailyRow))
  ) {
    return false;
  }
  if (value.fullSuiteMinScenarios !== undefined && typeof value.fullSuiteMinScenarios !== "number") {
    return false;
  }
  if (
    value.machines !== undefined &&
    (!Array.isArray(value.machines) ||
      !value.machines.every(
        (m) => isRecord(m) && typeof m.host === "string" && typeof m.machine === "string",
      ))
  ) {
    return false;
  }
  if (
    value.runStats !== undefined &&
    (!Array.isArray(value.runStats) ||
      !value.runStats.every(
        (s) =>
          isRecord(s) &&
          typeof s.runID === "string" &&
          isOptNumber(s.wallClockMs) &&
          isOptString(s.testStartedAt) &&
          isOptString(s.testFinishedAt) &&
          isOptNumber(s.testTimeMs) &&
          typeof s.scenarioTotalMs === "number" &&
          typeof s.scenarioCount === "number" &&
          typeof s.laneCount === "number" &&
          isOptNumber(s.maxScenarioMs) &&
          isOptString(s.maxScenarioID),
      ))
  ) {
    return false;
  }
  // performance はキー欠落(旧 CLI)を許容するため undefined のみ特別扱いする。
  if (value.performance !== undefined && !isPerformanceReport(value.performance)) {
    return false;
  }
  return true;
}

export function isDashboardFromWebviewMessage(value: unknown): value is DashboardFromWebviewMessage {
  if (!isRecord(value)) return false;
  if (value.type === "ready" || value.type === "refresh") return true;
  if (value.type === "runDetail") {
    return (
      typeof value.runID === "string" &&
      (value.runIDs === undefined ||
        (Array.isArray(value.runIDs) && value.runIDs.every((id) => typeof id === "string")))
    );
  }
  if (value.type === "trend") return typeof value.scenarioID === "string";
  if (value.type === "openReport") return typeof value.path === "string";
  if (value.type === "selectProject") return typeof value.project === "string";
  return false;
}
