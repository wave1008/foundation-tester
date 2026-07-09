// model.ts
// ftester CLI (`ftester api ...`) が入出力する JSON/NDJSON の型定義。
// run 系(RunEvent)は Sources/FTCore/ScenarioEvent.swift(ScenarioEvent)と
// Sources/ftester/ApiRunCommand.swift(runStarted/runFinished)の実装に合わせた
// kind 判別の共用体。フィールドは概ね optional(Swift 側は同じ struct を全 kind で
// 使い回しており、kind ごとに使うフィールドだけを埋めるため)。

/** `ftester api list-scenarios --project <P>` の出力(1行JSON)。 */
export interface ListScenariosResult {
  project: string;
  repoRoot: string;
  scenariosDir: string;
  folders: string[];
  scenarios: ScenarioInfo[];
}

export interface ScenarioInfo {
  /** "クラス名.メソッド名" 形式のシナリオID(日本語を含む生文字列)。 */
  id: string;
  title: string;
  deleted: boolean;
  file: string;
  classLine: number | null;
  methodLine: number | null;
  folder: string | null;
}

/** `ftester api steps --project P --scenario ID` の出力(1行JSON)。後続フェーズで使用。 */
export interface StepsResult {
  scenario: string;
  steps: StepRow[];
}

export type StepSection = "condition" | "action" | "expectation";

export interface StepRow {
  index: number;
  scene: number;
  sceneTitle: string;
  section: StepSection;
  command: string;
  comment: string | null;
  generatedComment: string | null;
  /** リポジトリ相対パス。 */
  file: string;
  line: number;
}

/** `ftester api run ...` が1行ずつ出力するイベントの kind。 */
export type RunEventKind =
  | "runStarted"
  | "workersReady"
  | "scenarioStarted"
  | "sceneStarted"
  | "step"
  | "sceneFinished"
  | "fixSuggestion"
  | "paused"
  | "scenarioFinished"
  | "log"
  | "runFinished";

const RUN_EVENT_KINDS: ReadonlySet<string> = new Set<RunEventKind>([
  "runStarted",
  "workersReady",
  "scenarioStarted",
  "sceneStarted",
  "step",
  "sceneFinished",
  "fixSuggestion",
  "paused",
  "scenarioFinished",
  "log",
  "runFinished",
]);

/** 並列実行(`--profile` 指定時)のワーカー(デバイス)1台分の情報。 */
export interface WorkerInfo {
  /** モニタータイルの device id と同一規則("ios:シミュ1" / "android:エミュ1")。 */
  id: string;
  name: string;
  platform: "ios" | "android";
  detail: string;
}

/**
 * `runStarted` 直後、並列実行(`--profile` 指定・非dry-run・非debug)のときだけ出力される。
 * 以降の全イベントに `worker` フィールド(この workers[].id のいずれか)が付く合図。
 */
export interface WorkersReadyEvent {
  kind: "workersReady";
  workers: WorkerInfo[];
}

/** ScenarioEvent.swift の StepResult.Status.eventStatus が返す status 文字列。 */
export type StepStatus = "passed" | "passedViaFallback" | "healed" | "failed" | "skipped";

/** ScenarioEvent.swift の section フィールド(CAE ブロック外は undefined)。 */
export type RunStepSection = "condition" | "action" | "expectation";

/** ApiRunCommand.swift の ApiRunStartedEvent。 */
export interface RunStartedEvent {
  kind: "runStarted";
  total: number;
}

/** ScenarioEvent(kind: "scenarioStarted")。 */
export interface ScenarioStartedEvent {
  kind: "scenarioStarted";
  scenario: string;
  title?: string;
  /** 並列実行時のみ付与される担当ワーカー id(WorkersReadyEvent.workers[].id と同一規則)。 */
  worker?: string;
}

/** ScenarioEvent(kind: "sceneStarted")。 */
export interface SceneStartedEvent {
  kind: "sceneStarted";
  scenario: string;
  scene?: number;
  sceneTitle?: string;
  worker?: string;
}

/** ScenarioEvent(kind: "step")。tap/exist 等 1 操作分の結果。 */
export interface StepEvent {
  kind: "step";
  scenario: string;
  scene?: number;
  sceneTitle?: string;
  section?: RunStepSection;
  index?: number;
  description?: string;
  status: StepStatus;
  /** 失敗理由・フォールバック内容・スキップ理由など(status に応じて意味が変わる)。 */
  detail?: string;
  /** コマンド呼び出し元のソース位置(リポジトリルート相対)。 */
  file?: string;
  /** 1 起点の行番号。 */
  line?: number;
  worker?: string;
}

/** ScenarioEvent(kind: "sceneFinished")。 */
export interface SceneFinishedEvent {
  kind: "sceneFinished";
  scenario: string;
  scene?: number;
  sceneTitle?: string;
  passed: boolean;
  worker?: string;
}

/** ScenarioEvent(kind: "fixSuggestion")。GUI の確認シート用の旧セレクタ・新セレクタを含む。 */
export interface FixSuggestionEvent {
  kind: "fixSuggestion";
  scenario?: string;
  description?: string;
  detail?: string;
  file?: string;
  line?: number;
  oldSelector?: string;
  newSelector?: string;
  worker?: string;
}

/** ScenarioEvent(kind: "paused")。--debug 実行時のみ発生する(debugAdapter.ts が処理する)。 */
export interface PausedEvent {
  kind: "paused";
  scenario?: string;
  index?: number;
  description?: string;
  /** コマンド呼び出し元のソース位置(リポジトリルート相対)。 */
  file?: string;
  /** 1 起点の行番号。 */
  line?: number;
  scene?: number;
  section?: RunStepSection;
}

/** ScenarioEvent(kind: "scenarioFinished")。 */
export interface ScenarioFinishedEvent {
  kind: "scenarioFinished";
  scenario: string;
  passed: boolean;
  reportPath?: string;
  worker?: string;
}

/** ScenarioEvent(kind: "log")。ユーザー print の混入行などホスト側の付随情報。 */
export interface LogEvent {
  kind: "log";
  scenario?: string;
  message?: string;
  worker?: string;
}

/** ApiRunCommand.swift の ApiRunFinishedEvent。 */
export interface RunFinishedEvent {
  kind: "runFinished";
  passed: number;
  failed: number;
}

/** NDJSON の1行分のイベント(kind で判別する共用体)。 */
export type RunEvent =
  | RunStartedEvent
  | WorkersReadyEvent
  | ScenarioStartedEvent
  | SceneStartedEvent
  | StepEvent
  | SceneFinishedEvent
  | FixSuggestionEvent
  | PausedEvent
  | ScenarioFinishedEvent
  | LogEvent
  | RunFinishedEvent;

/**
 * cli.ts の onNdjsonValue から渡される unknown(NdjsonParser が JSON.parse しただけの値)を
 * RunEvent として扱ってよいか判定する。既知の kind 以外(将来の追加や壊れた行)は false を返す
 * ので、呼び出し側は安全に無視できる。
 */
export function isRunEvent(value: unknown): value is RunEvent {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const kind = (value as { kind?: unknown }).kind;
  return typeof kind === "string" && RUN_EVENT_KINDS.has(kind);
}
