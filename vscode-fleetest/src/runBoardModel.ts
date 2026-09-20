// runBoardModel.ts
// デバイスモニターの「run ボード」(フリート横断の実行状況。docs/design.md §18)の純粋ロジック。
// vscode に依存しない(machineLockModel.ts と同じ立場)。**表示文字列は置かない** —— この
// ファイルは拡張バンドルと webview バンドルの両方に入る(src/webview/monitor/runBoard.js が
// 直接 import する。runLaneModel.ts と同じ形)ため、i18n/index.ts を import できない
// (CLAUDE.md「拡張と webview の両バンドルに入る .ts」の罠)。文言は呼び手が t() で作る。
//
// 供給元: `fleetest api monitor` の monitorRuns イベント(1行 = 1機械ぶん。machine 欠落 = 手元。
// monitorDeviceModel.ts の MonitorRunEntry/MonitorRunLane が生の NDJSON 型)。

/** 手元(machine 欠落)を表す内部キー。hostCharts.js の HM_LOCAL_LABEL(機械名の行キー)と
 * 同じ規律 —— 表示側で "local" という語に変換するのは呼び手(runBoard.js)の仕事。 */
export const LOCAL_MACHINE_KEY = "";

// **`remaining`(レーンごとの残り本数)は持たない** —— 供給側(FTCore.RunProgressLane)が
// 意図的に持たない欄(shared dispatch は同一 platform のレーンが1つのキューを共有するので、
// レーン別の残数は同じ数字が並ぶだけで誤読を招く)。run 全体の残りは total - done で足りる。
export interface RunBoardLane {
  readonly key: string;
  readonly name: string;
  readonly platform?: "ios" | "android";
  /** 実行中のシナリオ ID。**省略 = 待機中**(直前の1本を終えて次を待つ)。 */
  readonly scenario?: string;
  /** `scenario` が無いときは省略。 */
  readonly scenarioElapsedSeconds?: number;
}

/** 1 run(1機械ぶん)。ネットワークから届く生の形(machine/receivedAtMs は畳み込みの側が足す)。 */
export interface RunBoardRawRun {
  readonly pid: number;
  /** "building"(シナリオのビルド中)/ "preparing"(デバイスの供給中)/ "running"。 */
  readonly phase: string;
  /** 結果を捨てて振り直した累計。 */
  readonly requeued: number;
  /** レーンが離脱した累計。 */
  readonly laneDropouts: number;
  /** `RunRecorder` が無い経路(--dry-run/--debug 等)では省略されうる。省略時は pid が代わりの鍵。 */
  readonly runID?: string;
  readonly runGroup?: string;
  readonly issuer?: string;
  readonly mine: boolean;
  readonly project: string;
  /** プロファイル無し実行では省略されうる。 */
  readonly profile?: string;
  readonly elapsedSeconds: number;
  readonly total: number;
  readonly done: number;
  readonly failed: number;
  readonly etaSeconds?: number;
  readonly lanes: readonly RunBoardLane[];
}

/** 控えに畳んだあとの1 run。machine は undefined = 手元(MonitorDevice.machine と同じ規約)。 */
export interface RunBoardRun extends RunBoardRawRun {
  readonly machine?: string;
  /** applyMonitorRunsEvent がこの run を畳んだ時刻(ms)。elapsedSeconds/etaSeconds はこの時刻
   * 時点の値なので、秒読みは読み手が (now - receivedAtMs)/1000 を足して進める(docs/design.md §18.3)。 */
  readonly receivedAtMs: number;
}

/** 1機械ぶんの控え。observed:false でも runs は消さない(machineLockModel.ts の
 * MachineLock と同じ理由 —— 「不明」と「無い」を混ぜないための保持で、**実際の表示・集計は
 * observed===true のときしか読まない**。呼び手は machineRunStatus / buildRunGroups を通すこと)。 */
export interface MachineRunsEntry {
  readonly observed: boolean;
  readonly runs: readonly RunBoardRun[];
}

/** applyMonitorRunsEvent への入力(monitorRuns イベント1件。webview 側は postMessage の
 * "monitorRuns" 型をそのまま渡せる形にしてある)。 */
export interface MonitorRunsEventInput {
  readonly machine?: string;
  readonly observed: boolean;
  readonly runs: readonly RunBoardRawRun[];
}

/** monitorRuns イベント1件を控えへ畳む(不変。新しい Map を返す。machineLockModel.ts の
 * applyMachineLockEvent と同じ形)。 */
export function applyMonitorRunsEvent(
  current: ReadonlyMap<string, MachineRunsEntry>,
  event: MonitorRunsEventInput,
  nowMs: number = Date.now(),
): Map<string, MachineRunsEntry> {
  const key = event.machine ?? LOCAL_MACHINE_KEY;
  const next = new Map(current);
  if (!event.observed) {
    // **控えを消さない**(machineLockModel.ts と同じ理由)。直前の一覧は残すが、observed:false の
    // 間は buildRunGroups/machineRunStatus のどちらも読まない = 表示には出ない。
    const previous = current.get(key);
    next.set(key, { observed: false, runs: previous?.runs ?? [] });
    return next;
  }
  next.set(key, {
    observed: true,
    runs: event.runs.map((run) => ({ ...run, machine: event.machine, receivedAtMs: nowMs })),
  });
  return next;
}

export type MachineRunStatus = "running" | "idle" | "unknown";

/** ヘッダの機械要約(● 実行中 / ○ 空き / ? 不明)。控えが無い機械(一度も monitorRuns を
 * 受けていない)も unknown —— 「不明」と「空き」を混ぜない(観測できているが 0 本だけが idle)。 */
export function machineRunStatus(
  state: ReadonlyMap<string, MachineRunsEntry>,
  machine: string,
): MachineRunStatus {
  const entry = state.get(machine);
  if (!entry || !entry.observed) {
    return "unknown";
  }
  return entry.runs.length > 0 ? "running" : "idle";
}

export interface RunBoardGroup {
  /** runGroup → runID → `<machine>#<pid>` の順(単機 run はそれ自身で1グループ。
   * docs/design.md §18.5)。runID も省略されうる経路(--dry-run/--debug 等)があるので
   * pid まで落ちるが、**pid は機械ごとの番号なので機械名で名前空間を切る**。 */
  readonly groupKey: string;
  readonly mine: boolean;
  readonly issuer?: string;
  readonly project: string;
  /** プロファイル無し実行では省略されうる。 */
  readonly profile?: string;
  /** 束ねた run 全体の合計(機械分担の run はレーンでなく run 単位で合算する)。 */
  /** **束ねた run の中で最も進んだ段階**(1つでも走り出していれば "running")。機械分担の run は
   * 機械ごとに進みが違うので、片方が走り出したら進捗を出す。 */
  readonly phase: "building" | "preparing" | "running";
  /** 束ねた run の合計。**事実だけ**(判定・警告はしない。docs/design.md §18.5)。 */
  readonly requeued: number;
  readonly laneDropouts: number;
  readonly total: number;
  readonly done: number;
  readonly failed: number;
  /** 経過は最も長く走っている run(= 束ねた中の最大)。receivedAtMs 時点の値 —— 秒読みは
   * liveElapsedSeconds(elapsedSeconds, receivedAtMs, now) で進める。 */
  readonly elapsedSeconds: number;
  /** 全 run が見積もりを持つときだけ最大値(直列化された下限)。1本でも欠けたら省く = 「—」。
   * receivedAtMs 時点の値(liveRemaining と組で使う)。 */
  readonly etaSeconds?: number;
  /** 束ねた run のうち最も古い受信時刻(ms)。機械分担の run は各機械が別々に届くため、
   * elapsedSeconds/etaSeconds の基準時刻として最も保守的な(= 遅れていない側の)値を使う。 */
  readonly receivedAtMs: number;
  /** 束ねた run(machine 昇順。"" が手元で必ず先頭に来る = 空文字は他のどの機械名よりも辞書順で先)。 */
  readonly runs: readonly RunBoardRun[];
}

/** observed:true の機械の run だけを runGroup で束ねる(docs/design.md §18.1/§18.5)。
 * unobserved の機械は丸ごと数えない・出さない(不明を実行中に混ぜない)。
 * 並びは「手元を含むグループ優先 → 先頭 run の machine 名 → groupKey」——
 * 複数 run が同時に走っているときの表示順を安定させるための判断で、設計に明記は無い。 */
export function buildRunGroups(state: ReadonlyMap<string, MachineRunsEntry>): readonly RunBoardGroup[] {
  const byGroupKey = new Map<string, RunBoardRun[]>();
  for (const entry of state.values()) {
    if (!entry.observed) {
      continue;
    }
    for (const run of entry.runs) {
      // **pid だけのときは機械名で名前空間を切る** —— pid は機械ごとに小さい数字なので、
      // 別の機械の同じ pid(41233 は両方にありうる)が1つの run に束ねられて進捗が合算される
      const key = run.runGroup ?? run.runID ?? `${run.machine ?? ""}#${run.pid}`;
      const list = byGroupKey.get(key);
      if (list) {
        list.push(run);
      } else {
        byGroupKey.set(key, [run]);
      }
    }
  }
  const groups: RunBoardGroup[] = [];
  for (const [groupKey, members] of byGroupKey) {
    const runs = [...members].sort((a, b) => (a.machine ?? "").localeCompare(b.machine ?? ""));
    // members は byGroupKey.set が要素ありで初期化するので必ず1件以上(noUncheckedIndexedAccess 対策の非null)。
    const first = runs[0]!;
    const etaValues = runs.map((r) => r.etaSeconds);
    const allHaveEta = etaValues.every((v) => v !== undefined);
    groups.push({
      groupKey,
      mine: first.mine,
      issuer: first.issuer,
      phase: mostAdvancedPhase(runs),
      requeued: sum(runs.map((run) => run.requeued)),
      laneDropouts: sum(runs.map((run) => run.laneDropouts)),
      project: first.project,
      profile: first.profile,
      total: sum(runs.map((r) => r.total)),
      done: sum(runs.map((r) => r.done)),
      failed: sum(runs.map((r) => r.failed)),
      elapsedSeconds: Math.max(...runs.map((r) => r.elapsedSeconds)),
      etaSeconds: allHaveEta ? Math.max(...(etaValues as number[])) : undefined,
      receivedAtMs: Math.min(...runs.map((r) => r.receivedAtMs)),
      runs,
    });
  }
  return groups.sort((a, b) => {
    const aLocal = a.runs.some((r) => r.machine === undefined);
    const bLocal = b.runs.some((r) => r.machine === undefined);
    if (aLocal !== bLocal) {
      return aLocal ? -1 : 1;
    }
    // 各グループの runs も1件以上保証されている(上の groups.push と同じ不変条件)。
    const machineOrder = (a.runs[0]!.machine ?? "").localeCompare(b.runs[0]!.machine ?? "");
    if (machineOrder !== 0) {
      return machineOrder;
    }
    return a.groupKey.localeCompare(b.groupKey);
  });
}

/** run が1本も走っていない機械(ボード展開時に本体へ並べる)。`machine` は
 * `LOCAL_MACHINE_KEY` = 手元。**"running" は返さない** —— run がある機械は run の行として
 * 出るので、ここに出すと同じ機械が2行になる。 */
export interface MachineWithoutRuns {
  readonly machine: string;
  readonly status: Exclude<MachineRunStatus, "running">;
}

/** `machines`(フリートに居る機械の母集団)のうち、`groups` のどの run も使っていないものを
 * 状態つきで返す。並びは `machines` の順(呼び手が local を先頭に置く)。
 * **観測できていない機械も落とさない**(「不明」として並べる = 空きと混ぜないための表示)。 */
export function machinesWithoutRuns(
  state: ReadonlyMap<string, MachineRunsEntry>,
  machines: readonly string[],
  groups: readonly RunBoardGroup[],
): readonly MachineWithoutRuns[] {
  const busy = new Set<string>();
  for (const group of groups) {
    for (const run of group.runs) {
      busy.add(run.machine ?? LOCAL_MACHINE_KEY);
    }
  }
  const result: MachineWithoutRuns[] = [];
  for (const machine of machines) {
    if (busy.has(machine)) {
      continue;
    }
    const status = machineRunStatus(state, machine);
    result.push({ machine, status: status === "running" ? "idle" : status });
  }
  return result;
}

/** 束ねた run の中で最も進んだ段階。1つでも走り出していれば進捗を出したいので running が最優先。 */
function mostAdvancedPhase(runs: readonly RunBoardRun[]): "building" | "preparing" | "running" {
  if (runs.some((run) => run.phase === "running")) {
    return "running";
  }
  return runs.some((run) => run.phase === "preparing") ? "preparing" : "building";
}

function sum(values: readonly number[]): number {
  return values.reduce((total, value) => total + value, 0);
}

/** 経過秒の秒読み(webview の時計で進める。docs/design.md §18.3)。負にはならない。 */
export function liveElapsedSeconds(baseSeconds: number, receivedAtMs: number, nowMs: number): number {
  return baseSeconds + Math.max(0, (nowMs - receivedAtMs) / 1000);
}

export interface LiveRemaining {
  /** 残り秒(0 未満にはならない)。超過中は 0。 */
  readonly remainingSeconds: number;
  /** 残り 0 を過ぎてなお経過した秒数(超過。超過していなければ undefined)。 */
  readonly overageSeconds?: number;
}

/** 残り見積もりの秒読み。etaSeconds は受信時点の値なので、経過した分だけ差し引く
 * (docs/design.md §18.4 の「残り ~0:00(+M:SS 超過)」を作るための値)。undefined(見積もり無し)
 * は undefined のまま返す = 呼び手は「—」を出す。 */
export function liveRemaining(
  etaSeconds: number | undefined,
  receivedAtMs: number,
  nowMs: number,
): LiveRemaining | undefined {
  if (etaSeconds === undefined) {
    return undefined;
  }
  const elapsedSinceReceipt = Math.max(0, (nowMs - receivedAtMs) / 1000);
  const remaining = etaSeconds - elapsedSinceReceipt;
  if (remaining >= 0) {
    return { remainingSeconds: remaining };
  }
  return { remainingSeconds: 0, overageSeconds: -remaining };
}
