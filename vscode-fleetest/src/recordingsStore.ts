// recordingsStore.ts
// 録画セッション(recordings/index.json のある run)の列挙・読み込み。fs 直読みのみで vscode 非依存
// (monitorRecordingsController.ts から呼ぶ。テストは test/recordingsStore.test.mjs)。
//
// レイアウト: <workspaceRoot>/TestProjects/<project>/results/runs/<YYYY-MM>/<runID>/
//   recordings/index.json(録画があった run のみ) / run.json / scenarios/<name>.json

import * as fs from "node:fs/promises";
import * as path from "node:path";
import { isRecordingIndex, type RecordingIndex } from "./recordingsModel";

export interface RecordingSessionSummary {
  readonly project: string;
  /** 代表 runID(束ねたセッションでは最初の run。recordingsOpen はこれを送る)。 */
  readonly runID: string;
  /** このセッションを構成する run(単機なら1件。runID 昇順)。 */
  readonly runIDs: readonly string[];
  readonly startedAt: string;
  /** 表示用のマシン名(登録名へ読み替え済み。sessionMachineLabel)。古い/壊れた run.json では null。 */
  readonly machine: string | null;
  /** 束ねたセッションの全マシン(初出順・重複排除。読めないものは除く)。 */
  readonly machines: readonly string[];
  readonly passed: number | null;
  readonly failed: number | null;
  /** recordings/index.json の同名フィールド(任意。無ければ null)。 */
  readonly clipsAttempted: number | null;
  readonly clipsFailed: number | null;
  /** 同上。無ければ false(フォールバックしていないと同じ扱い)。 */
  readonly encoderFallback: boolean;
  /** 束ね鍵(run.json の runGroup)。単機の run と旧記録では null = 束ねない。 */
  readonly runGroup: string | null;
}

/** 一覧の表示上限(新しい順)。 */
const SESSION_LIMIT = 50;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(filePath: string): Promise<unknown | null> {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    return null; // 存在しない/壊れた JSON は「無い」として扱う
  }
}

async function listDirNames(dir: string): Promise<string[]> {
  try {
    return (await fs.readdir(dir, { withFileTypes: true })).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch {
    return [];
  }
}

function stringField(obj: Record<string, unknown> | null, key: string): string | undefined {
  const v = obj?.[key];
  return typeof v === "string" ? v : undefined;
}

function numberField(obj: Record<string, unknown> | null, key: string): number | undefined {
  const v = obj?.[key];
  return typeof v === "number" ? v : undefined;
}

function booleanField(obj: Record<string, unknown> | null, key: string): boolean | undefined {
  const v = obj?.[key];
  return typeof v === "boolean" ? v : undefined;
}

/**
 * run.json 配置規則(Sources/FTCore/RunResultsStore.swift の runDir(resultsDir:runID:)と同じ導出。
 * 変更時は両方揃えること)。runID 先頭6桁が yyyyMM で無い(不正な runID)場合は "unknown" 配下。
 */
/**
 * **ホスト名 → 設定タブで付けたマシン名(ローカルエイリアス)**の読み替え表
 * (2026-08-26 ユーザー決定: 記録側はエイリアスを持たず、読み手が読み替える)。
 * 供給元は CLI が書く `.fleetest/remote-hosts/<ホスト>.json` の `host`(ホスト名)と
 * `machineAlias`(表示用のエイリアス)。**ファイル名=鍵はホスト**で、エイリアスは欄として
 * 持つだけ(Sources/FTCore/RemoteHostFacts.swift)。ディスパッチのたびに更新される。
 * **読み替えは表示だけ**で、LPT の同一マシン判定など記録側の照合は run.json の host のまま。
 * 表に無いホスト名はそのまま出す(まだディスパッチしていない機械・別の人の機械)。
 */
async function readMachineAliases(workspaceRoot: string): Promise<Map<string, string>> {
  const dir = path.join(workspaceRoot, ".fleetest", "remote-hosts");
  let files: string[];
  try {
    files = (await fs.readdir(dir)).filter((f) => f.endsWith(".json")).sort();
  } catch {
    return new Map();
  }
  const aliases = new Map<string, string>();
  for (const file of files) {
    const raw = await readJson(path.join(dir, file));
    const record = isRecord(raw) ? raw : null;
    // 旧レイアウト(ファイル名がエイリアス・欄が machine)も読む —— 更新前の受け手の
    // キャッシュが残っていても表示が空にならないように
    const host = stringField(record, "host") ?? stringField(record, "machine");
    const alias = stringField(record, "machineAlias") ?? file.slice(0, -".json".length);
    if (host === undefined || host === "" || alias === "") {
      continue;
    }
    // 同じ機械に複数のエイリアスが向いていたら **手元("local")を優先**し、他は先勝ち
    // (ファイル名昇順)。手元をリモート名で呼ぶと、同じ機械の run が2つの名前で並ぶ
    if (!aliases.has(host) || alias === "local") {
      aliases.set(host, alias);
    }
  }
  return aliases;
}

/** セッションのマシン表示名。run.json の `host`(ホスト名。旧記録は `machine`)を
 *  マシン名(エイリアス)へ読み替える。表に無ければホスト名のまま出す。 */
function sessionMachineLabel(
  meta: Record<string, unknown> | null, aliases: ReadonlyMap<string, string>,
): string | null {
  const host = stringField(meta, "host") ?? stringField(meta, "machine");
  if (host === undefined || host === "") {
    return null;
  }
  return aliases.get(host) ?? host;
}

function runDirFor(workspaceRoot: string, project: string, runID: string): string {
  const runsDir = path.join(workspaceRoot, "TestProjects", project, "results", "runs");
  if (runID.length < 6) {
    return path.join(runsDir, "unknown", runID);
  }
  const month = `${runID.slice(0, 4)}-${runID.slice(4, 6)}`;
  return path.join(runsDir, month, runID);
}

/** recordings/index.json のある run を新しい順(runID 降順)に列挙する。上限 SESSION_LIMIT 件。 */
export async function listRecordingSessions(workspaceRoot: string): Promise<RecordingSessionSummary[]> {
  const aliases = await readMachineAliases(workspaceRoot);
  const projectsDir = path.join(workspaceRoot, "TestProjects");
  const sessions: RecordingSessionSummary[] = [];
  for (const project of await listDirNames(projectsDir)) {
    const runsDir = path.join(projectsDir, project, "results", "runs");
    for (const month of await listDirNames(runsDir)) {
      const monthDir = path.join(runsDir, month);
      for (const runID of await listDirNames(monthDir)) {
        const runDir = path.join(monthDir, runID);
        const indexRaw = await readJson(path.join(runDir, "recordings", "index.json"));
        if (!isRecordingIndex(indexRaw)) {
          continue;
        }
        // isRecordingIndex は clipsAttempted/clipsFailed/encoderFallback の型を検証しない(型不一致でも
        // index 全体は有効なまま)ため、ここで record として再取得し stringField/numberField と同じ
        // 寛容さで読む。
        const indexRecord = indexRaw as unknown as Record<string, unknown>;
        const metaRaw = await readJson(path.join(runDir, "run.json"));
        const meta = isRecord(metaRaw) ? metaRaw : null;
        const machine = sessionMachineLabel(meta, aliases);
        sessions.push({
          project,
          runID,
          runIDs: [runID],
          startedAt: stringField(meta, "startedAt") ?? runID,
          machine,
          machines: machine === null ? [] : [machine],
          passed: numberField(meta, "passed") ?? null,
          failed: numberField(meta, "failed") ?? null,
          clipsAttempted: numberField(indexRecord, "clipsAttempted") ?? null,
          clipsFailed: numberField(indexRecord, "clipsFailed") ?? null,
          encoderFallback: booleanField(indexRecord, "encoderFallback") ?? false,
          runGroup: stringField(meta, "runGroup") ?? null,
        });
      }
    }
  }
  sessions.sort((a, b) => (a.runID < b.runID ? 1 : a.runID > b.runID ? -1 : 0));
  return mergeSessionsByRunGroup(sessions).slice(0, SESSION_LIMIT);
}

/**
 * **同じ実行から分かれた run を1セッションに束ねる**(docs/results-json.md の runGroup)。
 * デバイスが複数の機械にまたがるプロファイルは機械ごとに別 run になるため、束ねないと
 * 「Mac ごとにセッションが並ぶ」。鍵を持たない run(単機・2026-08-26 より前の記録)は
 * **束ねない** —— profile 名と開始時刻からの推測は、同じプロファイルの連続実行や
 * 機械間の時計ずれで別の実行を混ぜるので採らない。
 * 入力は runID 降順。代表は**最も古い run**(親が最初に起こした = 一覧の並びと同じ基準)。
 */
function mergeSessionsByRunGroup(sessions: readonly RecordingSessionSummary[]): RecordingSessionSummary[] {
  const merged: RecordingSessionSummary[] = [];
  const indexByGroup = new Map<string, number>();
  for (const session of sessions) {
    // 鍵はプロジェクトを跨がない(同じ鍵が別プロジェクトに出ることはないが、束ねる単位は
    // あくまで1プロジェクト内の run なので鍵に project を含める)
    const key = session.runGroup === null ? null : `${session.project}\u0000${session.runGroup}`;
    const at = key === null ? undefined : indexByGroup.get(key);
    if (key === null || at === undefined) {
      if (key !== null) {
        indexByGroup.set(key, merged.length);
      }
      merged.push(session);
      continue;
    }
    merged[at] = combineSessions(merged[at]!, session);
  }
  return merged;
}

/** 束ねた1件。件数は合計・開始時刻は最も早いもの・台とマシンは初出順で重複排除。 */
function combineSessions(
  first: RecordingSessionSummary,
  next: RecordingSessionSummary,
): RecordingSessionSummary {
  const sum = (a: number | null, b: number | null): number | null =>
    a === null && b === null ? null : (a ?? 0) + (b ?? 0);
  // 入力は runID 降順なので next のほうが古い。代表と開始時刻は古い側に寄せる
  const machines = [...first.machines];
  for (const machine of next.machines) {
    if (!machines.includes(machine)) {
      machines.push(machine);
    }
  }
  return {
    project: first.project,
    runID: next.runID,
    runIDs: [...first.runIDs, next.runID].sort(),
    startedAt: next.startedAt < first.startedAt ? next.startedAt : first.startedAt,
    machine: next.machine ?? first.machine,
    machines,
    passed: sum(first.passed, next.passed),
    failed: sum(first.failed, next.failed),
    clipsAttempted: sum(first.clipsAttempted, next.clipsAttempted),
    clipsFailed: sum(first.clipsFailed, next.clipsFailed),
    encoderFallback: first.encoderFallback || next.encoderFallback,
    runGroup: first.runGroup,
  };
}

/**
 * runID と同じセッション(= 同じ runGroup)を構成する run をすべて返す(runID 昇順)。
 * 鍵が無ければその run 単体。**再生ビューを開くときの解決はここだけ** —— webview から
 * 受け取った一覧を信じずにディスクから引き直す(一覧は古くなりうる)。
 */
export async function resolveSessionRunIDs(
  workspaceRoot: string, project: string, runID: string,
): Promise<string[]> {
  const meta = await readJson(path.join(runDirFor(workspaceRoot, project, runID), "run.json"));
  const group = stringField(isRecord(meta) ? meta : null, "runGroup");
  if (group === undefined || group === "") {
    return [runID];
  }
  const runsDir = path.join(workspaceRoot, "TestProjects", project, "results", "runs");
  const found: string[] = [];
  for (const month of await listDirNames(runsDir)) {
    const monthDir = path.join(runsDir, month);
    for (const candidate of await listDirNames(monthDir)) {
      const candidateMeta = await readJson(path.join(monthDir, candidate, "run.json"));
      if (stringField(isRecord(candidateMeta) ? candidateMeta : null, "runGroup") === group) {
        found.push(candidate);
      }
    }
  }
  return found.length === 0 ? [runID] : found.sort();
}

export interface RecordingSessionDetailRaw {
  readonly runDir: string;
  readonly index: RecordingIndex;
  /** 表示用のマシン名(登録名へ読み替え済み。sessionMachineLabel)。読めなければ null。 */
  readonly machine: string | null;
  /** scenarios/*.json の生 JSON(ScenarioRunRecord 相当)。検証・変換は呼び出し側
   * (recordingsModel.ts の extractScenarioFailureSource)が行う。 */
  readonly scenarios: readonly unknown[];
}

/** セッション詳細(index.json + scenarios/*.json)を読む。index.json が無い/壊れていれば null。 */
export async function loadRecordingSessionDetail(
  workspaceRoot: string,
  project: string,
  runID: string,
): Promise<RecordingSessionDetailRaw | null> {
  const runDir = runDirFor(workspaceRoot, project, runID);
  const indexRaw = await readJson(path.join(runDir, "recordings", "index.json"));
  if (!isRecordingIndex(indexRaw)) {
    return null;
  }
  const scenariosDir = path.join(runDir, "scenarios");
  let files: string[] = [];
  try {
    files = (await fs.readdir(scenariosDir)).filter((f) => f.endsWith(".json"));
  } catch {
    files = [];
  }
  const scenarios = (await Promise.all(files.map((f) => readJson(path.join(scenariosDir, f))))).filter(
    (s) => s !== null,
  );
  const metaRaw = await readJson(path.join(runDir, "run.json"));
  const machine = sessionMachineLabel(isRecord(metaRaw) ? metaRaw : null,
                                      await readMachineAliases(workspaceRoot));
  return { runDir, index: indexRaw, machine, scenarios };
}
