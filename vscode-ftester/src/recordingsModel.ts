// recordingsModel.ts
// 録画再生 UI の vscode 非依存ロジック(型ガード・純粋関数)。monitorRecordingsController.ts /
// recordingsStore.ts と test/recordingsModel.test.mjs の両方から使う。
//
// 契約(録画側実装。runDir = <workspaceRoot>/Projects/<project>/results/runs/<YYYY-MM>/<runID>/):
// - recordings/index.json は schemaVersion 2: { schemaVersion:2, recordings: [{ scenarioID, worker,
//   platform, file, segments }] }。**1エントリ = 1テスト関数(scenarioID)の mp4**(v1 の1ワーカー
//   1動画とは異なる)。file は runDir 相対。動画の0秒 = 先頭 segment の startedAt(クリップ自体が
//   そのテストの録画区間なので、壁時計→クリップ内位置は既存 offsetMsForWallClock がそのまま使える)。
//   エントリは開始時刻昇順。同一 scenarioID が複数(revive 再実行)ありうるが対応は最初にマッチした
//   エントリでよい(firstRecordingEntryByScenario)。schemaVersion!==2 の古い(v1)セッションは
//   isRecordingIndex が弾く(一覧に出さない)。
// - scenarios/<name>.json (ScenarioRunRecord, Sources/FTCore/RunRecord.swift): startedAt/worker/passed/
//   failedSteps[]/errorLogs のみ参照。failedSteps[].at(失敗確定の壁時計時刻)は古い記録には無い。
// - 同ファイルの optional `timeline`(全ステップがイベント順)は TEST EXPLORER 風ツリー用。
//   scene/sceneTitle/at/durationMs は要素ごとに欠落しうる。**古い記録には timeline 自体が無い**
//   → buildRecordingTree はその場合 scenes:[] のシナリオ単独ノードを返す(ツリーはリーフのみ)。

export interface RecordingSegment {
  readonly startedAt: string;
  readonly durationMs: number;
}

export interface RecordingEntry {
  readonly scenarioID: string;
  readonly worker: string;
  readonly platform: "ios" | "android";
  readonly file: string;
  readonly segments: readonly RecordingSegment[];
}

export interface RecordingIndex {
  readonly schemaVersion: number;
  readonly recordings: readonly RecordingEntry[];
}

/** recordingsSession 応答でwebviewへ渡す1シナリオ分の動画情報。videoUri は webview.asWebviewUri 済み。 */
export interface RecordingScenarioVideo {
  readonly scenarioID: string;
  readonly videoUri: string;
}

/**
 * scenarioID → 最初にマッチしたエントリ(revive 再実行等で同一 scenarioID が複数あっても先頭を
 * 採用する契約)。recordings は開始時刻昇順(契約)であること。エラー一覧・ツリーのオフセット計算・
 * 動画 URI 一覧の組み立て(monitorRecordingsController.ts)が共通で使う。
 */
export function firstRecordingEntryByScenario(
  recordings: readonly RecordingEntry[],
): ReadonlyMap<string, RecordingEntry> {
  const map = new Map<string, RecordingEntry>();
  for (const entry of recordings) {
    if (!map.has(entry.scenarioID)) {
      map.set(entry.scenarioID, entry);
    }
  }
  return map;
}

/** エラー一覧1件(オフセット計算済み)。offsetMs は動画内位置(ms、範囲外はclamp済み)。 */
export interface RecordingErrorEntry {
  readonly scenarioID: string;
  /** 失敗ステップのシーン番号/ステップ index。ツリー選択によるフィルター照合に使う
   * (errorLogs 由来の行や欠落時は null = シナリオ選択でのみマッチ)。 */
  readonly scene: number | null;
  readonly stepIndex: number | null;
  readonly sceneTitle: string | null;
  readonly description: string;
  readonly detail: string | null;
  readonly worker: string;
  readonly at: string;
  readonly offsetMs: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isRecordingSegment(value: unknown): value is RecordingSegment {
  return isRecord(value) && typeof value.startedAt === "string" && typeof value.durationMs === "number";
}

function isRecordingEntry(value: unknown): value is RecordingEntry {
  return (
    isRecord(value) &&
    typeof value.scenarioID === "string" &&
    typeof value.worker === "string" &&
    (value.platform === "ios" || value.platform === "android") &&
    typeof value.file === "string" &&
    Array.isArray(value.segments) &&
    value.segments.every(isRecordingSegment)
  );
}

/** recordings/index.json の生 JSON(JSON.parse 済み unknown)の検証。schemaVersion===2 必須
 * (v1 の1ワーカー1動画セッションは scenarioID を持たないため、ここで弾いて一覧に出さない)。 */
export function isRecordingIndex(value: unknown): value is RecordingIndex {
  return (
    isRecord(value) &&
    value.schemaVersion === 2 &&
    Array.isArray(value.recordings) &&
    value.recordings.every(isRecordingEntry)
  );
}

/**
 * 壁時計時刻(ISO8601)を、セグメント列(壁時計→動画内位置の対応表)から動画内オフセット(ms)へ変換する。
 * segments は開始時刻の昇順を仮定(recorder が書く順のまま渡すこと)。
 * - t がセグメント i の [startedAt, startedAt+durationMs) に入る: 先行セグメント長の合計 + (t - startedAt)
 * - t がセグメント間の欠落(前セグメント終了後・次セグメント開始前)に落ちる: 次セグメントの先頭
 * - t が全区間より前、または segments が空: 0
 * - t が全区間より後: 総尺(末尾)にclamp
 */
export function offsetMsForWallClock(segments: readonly RecordingSegment[], atISO: string): number {
  const t = Date.parse(atISO);
  if (segments.length === 0 || Number.isNaN(t)) {
    return 0;
  }
  let cumulative = 0;
  for (const seg of segments) {
    const start = Date.parse(seg.startedAt);
    if (Number.isNaN(start)) {
      cumulative += seg.durationMs;
      continue;
    }
    const end = start + seg.durationMs;
    if (t < start) {
      // 全区間より前(cumulative===0のとき)、またはセグメント間の欠落に落ちた場合の「次セグメント先頭」。
      return cumulative;
    }
    if (t < end) {
      return cumulative + (t - start);
    }
    cumulative += seg.durationMs;
  }
  return cumulative; // 全区間より後: 総尺にclamp
}

/** scenarios/<name>.json から録画エラー一覧の構成に必要な項目だけを抜き出した形。 */
export interface ScenarioFailureSource {
  readonly scenarioID: string;
  readonly worker: string;
  readonly startedAt: string;
  readonly failedSteps: readonly {
    readonly scene: number | null;
    readonly index: number | null;
    readonly sceneTitle: string | null;
    readonly description: string;
    readonly detail: string | null;
    readonly at: string | null;
  }[];
  readonly errorLogs: readonly string[];
}

/**
 * scenarios/<name>.json の生 JSON(unknown)から ScenarioFailureSource を抽出する。
 * 正常終了(passed:true)・失敗情報が何も無い(failedSteps/errorLogsともに空)場合は null
 * (呼び出し側で除外する)。必須フィールド欠落など読めない形は null。
 */
export function extractScenarioFailureSource(raw: unknown): ScenarioFailureSource | null {
  if (!isRecord(raw) || typeof raw.scenarioID !== "string" || typeof raw.startedAt !== "string") {
    return null;
  }
  if (raw.passed === true) {
    return null;
  }
  const worker = typeof raw.worker === "string" ? raw.worker : "";
  const failedStepsRaw = Array.isArray(raw.failedSteps) ? raw.failedSteps : [];
  const failedSteps = failedStepsRaw
    .filter(isRecord)
    .filter((step): step is Record<string, unknown> & { description: string } => typeof step.description === "string")
    .map((step) => ({
      scene: typeof step.scene === "number" ? step.scene : null,
      index: typeof step.index === "number" ? step.index : null,
      sceneTitle: typeof step.sceneTitle === "string" ? step.sceneTitle : null,
      description: step.description,
      detail: typeof step.detail === "string" ? step.detail : null,
      at: typeof step.at === "string" ? step.at : null,
    }));
  const errorLogsRaw = Array.isArray(raw.errorLogs) ? raw.errorLogs : [];
  const errorLogs = errorLogsRaw.filter((line): line is string => typeof line === "string");
  if (failedSteps.length === 0 && errorLogs.length === 0) {
    return null;
  }
  return { scenarioID: raw.scenarioID, worker, startedAt: raw.startedAt, failedSteps, errorLogs };
}

/**
 * 失敗シナリオ群 + 録画セグメント表からエラー一覧(オフセット計算済み・at 昇順)を組み立てる。
 * failedSteps があればステップ単位(at が無ければシナリオ startedAt にフォールバック)、
 * 無く errorLogs のみあればシナリオ1行(位置はシナリオ startedAt)。offsetMs はそのシナリオの
 * クリップ(scenarioID でマッチした録画エントリ)の segments で計算する。対応する録画が無い
 * シナリオは offsetMs=0(segments=[] として計算される)。
 */
export function buildRecordingErrorEntries(
  scenarios: readonly ScenarioFailureSource[],
  recordings: readonly RecordingEntry[],
): RecordingErrorEntry[] {
  const byScenario = firstRecordingEntryByScenario(recordings);
  const entries: RecordingErrorEntry[] = [];
  for (const scenario of scenarios) {
    const segments = byScenario.get(scenario.scenarioID)?.segments ?? [];
    if (scenario.failedSteps.length > 0) {
      for (const step of scenario.failedSteps) {
        const at = step.at ?? scenario.startedAt;
        entries.push({
          scenarioID: scenario.scenarioID,
          scene: step.scene,
          stepIndex: step.index,
          sceneTitle: step.sceneTitle,
          description: step.description,
          detail: step.detail,
          worker: scenario.worker,
          at,
          offsetMs: offsetMsForWallClock(segments, at),
        });
      }
    } else if (scenario.errorLogs.length > 0) {
      entries.push({
        scenarioID: scenario.scenarioID,
        scene: null,
        stepIndex: null,
        sceneTitle: null,
        description: scenario.errorLogs.join("\n"),
        detail: null,
        worker: scenario.worker,
        at: scenario.startedAt,
        offsetMs: offsetMsForWallClock(segments, scenario.startedAt),
      });
    }
  }
  entries.sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
  return entries;
}

// ---- 録画タブ再生ビューの TEST EXPLORER 風ツリー ------------------------------------------
// シナリオ→シーン→ステップの3階層。表示文字列(既定シーン名・空状態)はツリーのローカライズが
// webview 側(src/i18n/strings/recordings.ts)の責務なので、ここでは title は素の値(null 許容)の
// まま返し、既定名フォーマットは呼び出し側(recordingsTab.js)に委ねる。

/** ✓緑/✗赤/その他グレーの3分類のみ扱う("failed" だけ特別扱い。他は passed か other に丸める)。 */
export type RecordingTreeStatus = "passed" | "failed" | "other";

function classifyStatus(status: string): RecordingTreeStatus {
  if (status === "failed") return "failed";
  if (status === "passed") return "passed";
  return "other";
}

/** 配下に failed があれば failed。無ければ記録の passed/scenes[].passed(あれば)を優先し、
 * 無ければ配下ありで passed、配下なしで other(判定材料が無い)。 */
function aggregateStatus(
  childStatuses: readonly RecordingTreeStatus[],
  authoritativePassed: boolean | undefined,
): RecordingTreeStatus {
  if (childStatuses.some((s) => s === "failed")) {
    return "failed";
  }
  if (authoritativePassed !== undefined) {
    return authoritativePassed ? "passed" : "failed";
  }
  return childStatuses.length > 0 ? "passed" : "other";
}

export interface RecordingTreeStep {
  readonly index: number;
  readonly description: string;
  readonly status: RecordingTreeStatus;
  readonly offsetMs: number;
}

export interface RecordingTreeScene {
  readonly scene: number;
  readonly sceneTitle: string | null;
  readonly status: RecordingTreeStatus;
  /** シーククリック時の動画内オフセット(ms)。先頭ステップの開始時点。 */
  readonly offsetMs: number;
  readonly steps: readonly RecordingTreeStep[];
}

export interface RecordingTreeScenario {
  readonly scenarioID: string;
  /** @Test の説明文(表示ラベル。無ければ webview 側が method 名にフォールバック)。 */
  readonly title: string | null;
  /** シナリオ開始の壁時計時刻(ISO8601)。セッション横断の前/次テストナビの並び順に使う。 */
  readonly startedAt: string;
  readonly status: RecordingTreeStatus;
  /** シーククリック時の動画内オフセット(ms)。1エントリ=1シナリオのクリップなので常に 0
   * (クリップ先頭 = シナリオ開始)。 */
  readonly offsetMs: number;
  /** timeline が無い記録は空配列(ツリーはこのシナリオノードのみ、展開矢印も出さない)。 */
  readonly scenes: readonly RecordingTreeScene[];
}

interface RawTimelineStep {
  readonly scene: number | null;
  readonly sceneTitle: string | null;
  readonly index: number;
  readonly description: string;
  readonly status: string;
  readonly at: string | null;
  readonly durationMs: number | null;
}

/** scenarios/<name>.json から TEST EXPLORER 風ツリーの構築に必要な項目だけを抜き出した形。 */
export interface ScenarioTreeSource {
  readonly scenarioID: string;
  /** raw.title(@Test の説明文)。ツリーのテスト関数ノードの表示ラベルに使う(無ければ null)。 */
  readonly title: string | null;
  readonly startedAt: string;
  /** raw.passed(真偽値でなければ false 扱い。extractScenarioFailureSource と同じ規約)。 */
  readonly passed: boolean;
  /** raw.scenes[].passed(scene番号→passed)。シーン合否判定の優先ソースとして使う。 */
  readonly scenePassed: ReadonlyMap<number, boolean>;
  /** raw.timeline(欠落/非配列は空配列)。 */
  readonly timeline: readonly RawTimelineStep[];
}

function parseTimelineStep(value: unknown): RawTimelineStep | null {
  if (!isRecord(value) || typeof value.index !== "number" || typeof value.description !== "string" ||
      typeof value.status !== "string") {
    return null;
  }
  return {
    scene: typeof value.scene === "number" ? value.scene : null,
    sceneTitle: typeof value.sceneTitle === "string" ? value.sceneTitle : null,
    index: value.index,
    description: value.description,
    status: value.status,
    at: typeof value.at === "string" ? value.at : null,
    durationMs: typeof value.durationMs === "number" ? value.durationMs : null,
  };
}

/**
 * scenarios/<name>.json の生 JSON(unknown)から ScenarioTreeSource を抽出する。
 * scenarioID/startedAt が読めない形は null(呼び出し側で除外)。timeline の要素は index/description/
 * status が揃わないものを黙ってスキップする(壊れた1件のためにツリー全体を諦めない)。
 */
export function extractScenarioTreeSource(raw: unknown): ScenarioTreeSource | null {
  if (!isRecord(raw) || typeof raw.scenarioID !== "string" || typeof raw.startedAt !== "string") {
    return null;
  }
  const passed = raw.passed === true;
  const scenePassed = new Map<number, boolean>();
  if (Array.isArray(raw.scenes)) {
    for (const s of raw.scenes) {
      if (isRecord(s) && typeof s.scene === "number" && typeof s.passed === "boolean") {
        scenePassed.set(s.scene, s.passed);
      }
    }
  }
  const timeline = Array.isArray(raw.timeline)
    ? raw.timeline.map(parseTimelineStep).filter((s): s is RawTimelineStep => s !== null)
    : [];
  const title = typeof raw.title === "string" && raw.title !== "" ? raw.title : null;
  return { scenarioID: raw.scenarioID, title, startedAt: raw.startedAt, passed, scenePassed, timeline };
}

/** timeline を scene 番号でグルーピングする(欠落は0番、ScenarioRecordBuilder の event.scene ?? 0 と
 * 同じ規約)。出現順を保つ(timeline は元々イベント順のため、同一シーンの再出現は無い前提)。 */
function groupTimelineByScene(timeline: readonly RawTimelineStep[]): { scene: number; steps: RawTimelineStep[] }[] {
  const order: number[] = [];
  const bySceneNumber = new Map<number, RawTimelineStep[]>();
  for (const step of timeline) {
    const scene = step.scene ?? 0;
    let list = bySceneNumber.get(scene);
    if (!list) {
      list = [];
      bySceneNumber.set(scene, list);
      order.push(scene);
    }
    list.push(step);
  }
  return order.map((scene) => ({ scene, steps: bySceneNumber.get(scene) ?? [] }));
}

/**
 * ステップ開始の壁時計(ISO8601)。仕様: at − durationMs。どちらか欠落なら at のみ。
 * at 自体が無ければシーン内で at を持つ最初のステップの at、それも無ければシナリオ startedAt。
 */
function stepStartAtISO(step: RawTimelineStep, sceneFirstAt: string | null, scenarioStartedAt: string): string {
  if (step.at !== null) {
    if (step.durationMs !== null) {
      const t = Date.parse(step.at);
      if (!Number.isNaN(t)) {
        return new Date(t - step.durationMs).toISOString();
      }
    }
    return step.at;
  }
  return sceneFirstAt ?? scenarioStartedAt;
}

/**
 * 失敗有無に関わらず全シナリオからツリー(startedAt 昇順)を組み立てる。offsetMs は全ノードで
 * 動画内オフセット計算済み(recordings/index.json の segments を scenarioID で引いて
 * offsetMsForWallClock に通す。対応する録画が無ければ segments=[] で 0 になる)。
 */
export function buildRecordingTree(
  scenarios: readonly ScenarioTreeSource[],
  recordings: readonly RecordingEntry[],
): RecordingTreeScenario[] {
  const byScenario = firstRecordingEntryByScenario(recordings);
  const ordered = [...scenarios].sort((a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt));
  return ordered.map((scenario) => {
    const segments = byScenario.get(scenario.scenarioID)?.segments ?? [];
    const scenes: RecordingTreeScene[] = groupTimelineByScene(scenario.timeline).map((group) => {
      const sceneFirstAt = group.steps.find((s) => s.at !== null)?.at ?? null;
      const steps: RecordingTreeStep[] = group.steps.map((step) => ({
        index: step.index,
        description: step.description,
        status: classifyStatus(step.status),
        offsetMs: offsetMsForWallClock(segments, stepStartAtISO(step, sceneFirstAt, scenario.startedAt)),
      }));
      const sceneTitle = group.steps.find((s) => s.sceneTitle !== null)?.sceneTitle ?? null;
      return {
        scene: group.scene,
        sceneTitle,
        status: aggregateStatus(steps.map((s) => s.status), scenario.scenePassed.get(group.scene)),
        offsetMs: steps[0]?.offsetMs ?? offsetMsForWallClock(segments, scenario.startedAt),
        steps,
      };
    });
    return {
      scenarioID: scenario.scenarioID,
      title: scenario.title,
      startedAt: scenario.startedAt,
      status: aggregateStatus(scenes.map((s) => s.status), scenario.passed),
      offsetMs: 0, // クリップ先頭 = シナリオ開始(1エントリ=1シナリオの契約)
      scenes,
    };
  });
}

/** テスト関数ノード。method は scenarioID の最後のドット以降(表示ラベル用)。 */
export interface RecordingTreeClassScenario extends RecordingTreeScenario {
  readonly method: string;
}

/** ツリー最上位のテストクラスノード。 */
export interface RecordingTreeClass {
  readonly classID: string;
  readonly status: RecordingTreeStatus;
  /** クラス内最初のシナリオの scenarioID(クラスクリックでこの動画の先頭[offset 0]へ切り替える)。 */
  readonly firstScenarioID: string;
  readonly scenarios: readonly RecordingTreeClassScenario[];
}

/**
 * buildRecordingTree の結果(startedAt 昇順)をテストクラスでグルーピングする。
 * scenarioID は「クラス名.メソッド名」形式(最後のドットで分割。ドットが無ければ全体を
 * クラス名兼メソッド名として1件クラスにする)。クラス順は最初に現れたシナリオの順を保つ。
 */
export function groupTreeByClass(scenarios: readonly RecordingTreeScenario[]): RecordingTreeClass[] {
  const byClass = new Map<string, RecordingTreeClassScenario[]>();
  for (const scenario of scenarios) {
    const dot = scenario.scenarioID.lastIndexOf(".");
    const classID = dot > 0 ? scenario.scenarioID.slice(0, dot) : scenario.scenarioID;
    const method = dot > 0 ? scenario.scenarioID.slice(dot + 1) : scenario.scenarioID;
    const list = byClass.get(classID);
    if (list) {
      list.push({ ...scenario, method });
    } else {
      byClass.set(classID, [{ ...scenario, method }]);
    }
  }
  return [...byClass.entries()].map(([classID, list]) => {
    const first = list[0];
    return {
      classID,
      status: aggregateStatus(list.map((s) => s.status), undefined),
      firstScenarioID: first?.scenarioID ?? "",
      scenarios: list,
    };
  });
}
