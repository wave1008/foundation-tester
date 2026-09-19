// resultsExportModel.ts
// scenarios/*.json(ScenarioRunRecord)・run.json(の抜粋。RunMetaFragment)を、テスト結果
// エクスポート(「テストセッション」タブ)向けの中立なレポートモデルへ変換する vscode 非依存の
// 純粋ロジック(fs/vscode は monitorRecordingsController.ts 側が持つ)。xlsx への描画(スタイル・
// locale 依存の文言)は resultsExportWorkbook.ts の責務——このファイルは locale に依存しない
// データ構造だけを返す(t() を呼ばない)。
//
// **重複シナリオ規則**: 同一 run 内の再実行は scenarios/<id>~2.json のように連番で追加される
// (docs/results-json.md「git での扱い」)。録画タブの TEST EXPLORER ツリー
// (recordingsModel.ts の buildRecordingTree/groupTreeByClass)は de-dup せず全ファイルを
// それぞれ1行として startedAt 昇順に並べる契約なので、本レポートも同じ規則を踏襲する。

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function pushDistinct(list: string[], seen: Set<string>, value: string | null): void {
  if (value === null || value === "" || seen.has(value)) {
    return;
  }
  seen.add(value);
  list.push(value);
}

// ---- 抽出(raw JSON → 中立なソース形) --------------------------------------------------------

export interface ResultsExportTimelineStep {
  readonly scene: number | null;
  readonly sceneTitle: string | null;
  /** condition/action/expectation/setUp/tearDown。CAE ブロック外・旧レコードは null。 */
  readonly section: string | null;
  readonly index: number;
  readonly description: string;
  /** ScenarioEvent.status そのまま(passed/passedViaFallback/healed/failed/skipped 等)。 */
  readonly status: string;
  readonly durationMs: number | null;
  readonly notes: readonly string[];
}

export interface ResultsExportFailedStep {
  readonly index: number | null;
  readonly scene: number | null;
  readonly sceneTitle: string | null;
  readonly description: string;
  readonly command: string | null;
  readonly failureKind: string | null;
  readonly detail: string | null;
  readonly notes: readonly string[];
  /** ワークスペースルート相対(docs/results-json.md の FailedStepRecord.file)。 */
  readonly file: string | null;
  readonly line: number | null;
}

export interface ResultsExportScenarioSource {
  readonly scenarioID: string;
  readonly className: string;
  readonly methodName: string;
  readonly title: string | null;
  /** "ios" / "android" / 読めなければ null。 */
  readonly platform: string | null;
  readonly worker: string | null;
  /** run.json 由来のマシン名(alias 解決済み。呼び出し側 = monitorRecordingsController.ts が渡す)。 */
  readonly machine: string | null;
  readonly profile: string | null;
  readonly passed: boolean;
  readonly timedOut: boolean;
  readonly interrupted: boolean;
  readonly skipKind: string | null;
  readonly startedAt: string | null;
  readonly durationMs: number;
  /** steps.healed + steps.passedViaFallback(StepCountsRecord)。 */
  readonly healedCount: number;
  readonly errorLogs: readonly string[];
  readonly timeline: readonly ResultsExportTimelineStep[];
  readonly failedSteps: readonly ResultsExportFailedStep[];
  /** 動画の絶対パス(録画が無ければ null。呼び出し側が firstRecordingEntryByScenario で解決)。 */
  readonly videoPath: string | null;
}

function parseTimelineStep(value: unknown): ResultsExportTimelineStep | null {
  if (!isRecord(value) || typeof value.index !== "number" || typeof value.description !== "string" ||
      typeof value.status !== "string") {
    return null;
  }
  return {
    scene: typeof value.scene === "number" ? value.scene : null,
    sceneTitle: typeof value.sceneTitle === "string" ? value.sceneTitle : null,
    section: typeof value.section === "string" ? value.section : null,
    index: value.index,
    description: value.description,
    status: value.status,
    durationMs: typeof value.durationMs === "number" ? value.durationMs : null,
    notes: Array.isArray(value.notes) ? value.notes.filter((n): n is string => typeof n === "string") : [],
  };
}

function parseFailedStep(value: unknown): ResultsExportFailedStep | null {
  if (!isRecord(value) || typeof value.description !== "string") {
    return null;
  }
  return {
    index: typeof value.index === "number" ? value.index : null,
    scene: typeof value.scene === "number" ? value.scene : null,
    sceneTitle: typeof value.sceneTitle === "string" ? value.sceneTitle : null,
    description: value.description,
    command: typeof value.command === "string" ? value.command : null,
    failureKind: typeof value.failureKind === "string" ? value.failureKind : null,
    detail: typeof value.detail === "string" ? value.detail : null,
    notes: Array.isArray(value.notes) ? value.notes.filter((n): n is string => typeof n === "string") : [],
    file: typeof value.file === "string" ? value.file : null,
    line: typeof value.line === "number" ? value.line : null,
  };
}

function readHealedCount(raw: Record<string, unknown>): number {
  const steps = isRecord(raw.steps) ? raw.steps : null;
  const healed = typeof steps?.healed === "number" ? steps.healed : 0;
  const passedViaFallback = typeof steps?.passedViaFallback === "number" ? steps.passedViaFallback : 0;
  return healed + passedViaFallback;
}

/**
 * scenarios/<name>.json の生 JSON(unknown)から ResultsExportScenarioSource を抽出する。
 * scenarioID が読めない形は null(呼び出し側で除外)。profile はレコード自身の値を優先し、
 * 欠落時だけ引数の run 側フォールバック(run.json 由来)を使う(旧レコードは自身の値を持たない)。
 * クラス名/メソッド名は scenarioID の最後のドットで分割(ドット無しは全体をクラス名兼メソッド名にする。
 * recordingsModel.ts の groupTreeByClass と同じ規則)。
 */
export function extractResultsExportScenarioSource(
  raw: unknown,
  fallbackProfile: string | null,
  machine: string | null,
  videoPath: string | null,
): ResultsExportScenarioSource | null {
  if (!isRecord(raw) || typeof raw.scenarioID !== "string") {
    return null;
  }
  const scenarioID = raw.scenarioID;
  const dot = scenarioID.lastIndexOf(".");
  const className = dot > 0 ? scenarioID.slice(0, dot) : scenarioID;
  const methodName = dot > 0 ? scenarioID.slice(dot + 1) : scenarioID;

  const timeline = Array.isArray(raw.timeline)
    ? raw.timeline.map(parseTimelineStep).filter((s): s is ResultsExportTimelineStep => s !== null)
    : [];
  const failedSteps = Array.isArray(raw.failedSteps)
    ? raw.failedSteps.map(parseFailedStep).filter((s): s is ResultsExportFailedStep => s !== null)
    : [];
  const errorLogs = Array.isArray(raw.errorLogs) ? raw.errorLogs.filter((l): l is string => typeof l === "string") : [];

  return {
    scenarioID,
    className,
    methodName,
    title: typeof raw.title === "string" && raw.title !== "" ? raw.title : null,
    platform: typeof raw.platform === "string" ? raw.platform : null,
    worker: typeof raw.worker === "string" ? raw.worker : null,
    machine,
    profile: (typeof raw.profile === "string" && raw.profile !== "" ? raw.profile : null) ?? fallbackProfile,
    passed: raw.passed === true,
    timedOut: raw.timedOut === true,
    interrupted: raw.interrupted === true,
    skipKind: typeof raw.skipKind === "string" ? raw.skipKind : null,
    startedAt: typeof raw.startedAt === "string" ? raw.startedAt : null,
    durationMs: typeof raw.durationMs === "number" ? raw.durationMs : 0,
    healedCount: readHealedCount(raw),
    errorLogs,
    timeline,
    failedSteps,
    videoPath,
  };
}

// ---- run.json 抜粋(概要シート) ------------------------------------------------------------

export interface ResultsExportFmSettings {
  readonly heal: boolean | null;
  readonly textVisualCheck: boolean | null;
  readonly screenLooksLike: boolean | null;
  readonly ocrTextVisualCheck: boolean | null;
}

export interface ResultsExportRunMeta {
  readonly runID: string;
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
  readonly trigger: string | null;
  readonly issuer: string | null;
  readonly profile: string | null;
  /** run.json 由来のマシン名(alias 解決済み)。 */
  readonly machine: string | null;
  readonly fmSettings: ResultsExportFmSettings | null;
}

// ---- モデル(レポートの行構造) ---------------------------------------------------------------

export type ResultsExportScenarioResult = "success" | "failure" | "timeout" | "interrupted" | "skipped";

export interface ResultsExportScenarioRow {
  readonly scenarioID: string;
  readonly className: string;
  readonly method: string;
  readonly title: string | null;
  readonly platform: string | null;
  readonly worker: string | null;
  readonly machine: string | null;
  readonly result: ResultsExportScenarioResult;
  readonly durationMs: number;
  readonly startedAt: string | null;
  readonly healedCount: number;
  readonly failedScene: number | null;
  readonly failedSceneTitle: string | null;
  readonly failedStepDescription: string | null;
  readonly failureKind: string | null;
  /** 失敗ステップの detail、無ければ timedOut/interrupted/skipKind + errorLogs の合成文。成功なら null。 */
  readonly reason: string | null;
  readonly failedStepNotes: readonly string[];
  /** ワークスペースルート相対。 */
  readonly sourceFile: string | null;
  readonly sourceLine: number | null;
  readonly videoPath: string | null;
  readonly timeline: readonly ResultsExportTimelineStep[];
}

export interface ResultsExportClassSummary {
  readonly classID: string;
  readonly scenarioCount: number;
  readonly passedCount: number;
  /** 失敗・タイムアウト・中断(スキップは別欄。概要の内訳と食い違わせない)。 */
  readonly failedCount: number;
  readonly skippedCount: number;
  readonly durationMsSum: number;
}

export interface ResultsExportOverview {
  readonly project: string;
  /** run.json 開始時刻昇順。 */
  readonly runIDs: readonly string[];
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
  /** finishedAt − startedAt(秒)。どちらか欠落なら null。 */
  readonly durationSeconds: number | null;
  readonly profiles: readonly string[];
  readonly machines: readonly string[];
  readonly triggers: readonly string[];
  readonly issuers: readonly string[];
  /** 束ねた run のうち最初に見つかった非 null 値(run 間で食い違っても単一の代表値)。 */
  readonly fmSettings: ResultsExportFmSettings | null;
  readonly scenarioTotal: number;
  readonly scenarioPassed: number;
  readonly scenarioFailed: number;
  readonly scenarioTimedOut: number;
  readonly scenarioInterrupted: number;
  readonly scenarioSkipped: number;
  /** timeline 全件の状態別合計(steps.* ではなく timeline の実数を数える)。 */
  readonly stepTotal: number;
  readonly stepPassed: number;
  readonly stepHealed: number;
  readonly stepPassedViaFallback: number;
  readonly stepFailed: number;
  readonly stepSkipped: number;
}

export interface ResultsExportModel {
  readonly project: string;
  readonly overview: ResultsExportOverview;
  /** クラス初出順(シナリオの並び = startedAt 昇順から見た最初の登場順)。 */
  readonly classes: readonly ResultsExportClassSummary[];
  /** startedAt 昇順(壁時計。読めない値は末尾)。 */
  readonly scenarios: readonly ResultsExportScenarioRow[];
}

/** シナリオ全体の結果。skipKind → スキップ / timedOut → タイムアウト / interrupted → 中断 /
 *  passed → 成功 / それ以外 → 失敗。 */
function resultForSource(source: ResultsExportScenarioSource): ResultsExportScenarioResult {
  if (source.skipKind !== null) return "skipped";
  if (source.timedOut) return "timeout";
  if (source.interrupted) return "interrupted";
  if (source.passed) return "success";
  return "failure";
}

function scenarioLevelReasonText(source: ResultsExportScenarioSource): string {
  const flags: string[] = [];
  if (source.timedOut) flags.push("timedOut");
  if (source.interrupted) flags.push("interrupted");
  if (source.skipKind) flags.push(`skipKind: ${source.skipKind}`);
  return [flags.join(", "), ...source.errorLogs].filter((s) => s !== "").join("\n");
}

/** 1シナリオぶんのソースからシナリオ行を組み立てる。失敗ステップは高々1件の前提で先頭のみ使う
 *  (失敗はシナリオ全体を中断するため)。 */
function buildScenarioRow(source: ResultsExportScenarioSource): ResultsExportScenarioRow {
  const result = resultForSource(source);
  const failedStep = source.failedSteps[0] ?? null;
  const failedSceneTitle = failedStep
    ? failedStep.sceneTitle ?? source.timeline.find((s) => s.scene === failedStep.scene)?.sceneTitle ?? null
    : null;
  const reason = failedStep
    ? failedStep.detail
    : result === "success" ? null : scenarioLevelReasonText(source);
  return {
    scenarioID: source.scenarioID,
    className: source.className,
    method: source.methodName,
    title: source.title,
    platform: source.platform,
    worker: source.worker,
    machine: source.machine,
    result,
    durationMs: source.durationMs,
    startedAt: source.startedAt,
    healedCount: source.healedCount,
    failedScene: failedStep?.scene ?? null,
    failedSceneTitle,
    failedStepDescription: failedStep?.description ?? null,
    failureKind: failedStep?.failureKind ?? null,
    reason: reason === "" ? null : reason,
    failedStepNotes: failedStep?.notes ?? [],
    sourceFile: failedStep?.file ?? null,
    sourceLine: failedStep?.line ?? null,
    videoPath: source.videoPath,
    timeline: source.timeline,
  };
}

function buildClasses(scenarios: readonly ResultsExportScenarioRow[]): ResultsExportClassSummary[] {
  const order: string[] = [];
  const byClass = new Map<string, ResultsExportScenarioRow[]>();
  for (const row of scenarios) {
    let list = byClass.get(row.className);
    if (!list) {
      list = [];
      byClass.set(row.className, list);
      order.push(row.className);
    }
    list.push(row);
  }
  return order.map((classID) => {
    const rows = byClass.get(classID)!;
    const passedCount = rows.filter((r) => r.result === "success").length;
    const skippedCount = rows.filter((r) => r.result === "skipped").length;
    return {
      classID,
      scenarioCount: rows.length,
      passedCount,
      failedCount: rows.length - passedCount - skippedCount,
      skippedCount,
      durationMsSum: rows.reduce((sum, r) => sum + r.durationMs, 0),
    };
  });
}

function buildOverview(
  project: string,
  runMetas: readonly ResultsExportRunMeta[],
  scenarios: readonly ResultsExportScenarioRow[],
): ResultsExportOverview {
  let startedAt: string | null = null;
  let finishedAt: string | null = null;
  const profiles: string[] = [];
  const profilesSeen = new Set<string>();
  const machines: string[] = [];
  const machinesSeen = new Set<string>();
  const triggers: string[] = [];
  const triggersSeen = new Set<string>();
  const issuers: string[] = [];
  const issuersSeen = new Set<string>();
  let fmSettings: ResultsExportFmSettings | null = null;
  for (const meta of runMetas) {
    if (meta.startedAt !== null && (startedAt === null || meta.startedAt < startedAt)) startedAt = meta.startedAt;
    if (meta.finishedAt !== null && (finishedAt === null || meta.finishedAt > finishedAt)) finishedAt = meta.finishedAt;
    pushDistinct(profiles, profilesSeen, meta.profile);
    pushDistinct(machines, machinesSeen, meta.machine);
    pushDistinct(triggers, triggersSeen, meta.trigger);
    pushDistinct(issuers, issuersSeen, meta.issuer);
    if (fmSettings === null && meta.fmSettings !== null) fmSettings = meta.fmSettings;
  }
  const durationSeconds = startedAt !== null && finishedAt !== null
    ? (Date.parse(finishedAt) - Date.parse(startedAt)) / 1000
    : null;

  let scenarioTotal = 0, scenarioPassed = 0, scenarioFailed = 0, scenarioTimedOut = 0, scenarioInterrupted = 0, scenarioSkipped = 0;
  let stepTotal = 0, stepPassed = 0, stepHealed = 0, stepPassedViaFallback = 0, stepFailed = 0, stepSkipped = 0;
  for (const row of scenarios) {
    scenarioTotal++;
    switch (row.result) {
      case "success": scenarioPassed++; break;
      case "failure": scenarioFailed++; break;
      case "timeout": scenarioTimedOut++; break;
      case "interrupted": scenarioInterrupted++; break;
      case "skipped": scenarioSkipped++; break;
    }
    for (const step of row.timeline) {
      stepTotal++;
      switch (step.status) {
        case "passed": stepPassed++; break;
        case "passedViaFallback": stepPassedViaFallback++; break;
        case "healed": stepHealed++; break;
        case "failed": stepFailed++; break;
        case "skipped": stepSkipped++; break;
      }
    }
  }

  return {
    project,
    runIDs: runMetas.map((m) => m.runID),
    startedAt,
    finishedAt,
    durationSeconds,
    profiles,
    machines,
    triggers,
    issuers,
    fmSettings,
    scenarioTotal, scenarioPassed, scenarioFailed, scenarioTimedOut, scenarioInterrupted, scenarioSkipped,
    stepTotal, stepPassed, stepHealed, stepPassedViaFallback, stepFailed, stepSkipped,
  };
}

/**
 * 中立なシナリオソース列(すでに全 run から集めたもの。重複除去はしない)と run.json 抜粋から
 * ResultsExportModel を組み立てる。シナリオは startedAt 昇順(読めない/不正な値は末尾。NaN を
 * 比較関数へ返すと並びが不定になるので Infinity に倒す)、クラスは初出順。
 */
export function buildResultsExportModel(
  project: string,
  sources: readonly ResultsExportScenarioSource[],
  runMetas: readonly ResultsExportRunMeta[],
): ResultsExportModel {
  const startedMs = (s: ResultsExportScenarioSource) => {
    const ms = Date.parse(s.startedAt ?? "");
    return Number.isNaN(ms) ? Number.POSITIVE_INFINITY : ms;
  };
  const ordered = [...sources].sort((a, b) => {
    const da = startedMs(a);
    const db = startedMs(b);
    return da === db ? 0 : da < db ? -1 : 1;
  });
  const scenarios = ordered.map(buildScenarioRow);
  const classes = buildClasses(scenarios);
  const overview = buildOverview(project, runMetas, scenarios);
  return { project, overview, classes, scenarios };
}
