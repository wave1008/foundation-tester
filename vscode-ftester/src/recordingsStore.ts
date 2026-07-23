// recordingsStore.ts
// 録画セッション(recordings/index.json のある run)の列挙・読み込み。fs 直読みのみで vscode 非依存
// (monitorRecordingsController.ts から呼ぶ。テストは test/recordingsStore.test.mjs)。
//
// レイアウト: <workspaceRoot>/Projects/<project>/results/runs/<YYYY-MM>/<runID>/
//   recordings/index.json(録画があった run のみ) / run.json / scenarios/<name>.json

import * as fs from "node:fs/promises";
import * as path from "node:path";
import { isRecordingIndex, type RecordingIndex } from "./recordingsModel";

export interface RecordingSessionSummary {
  readonly project: string;
  readonly runID: string;
  readonly startedAt: string;
  readonly passed: number | null;
  readonly failed: number | null;
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

/**
 * run.json 配置規則(Sources/FTCore/RunResultsStore.swift の runDir(resultsDir:runID:)と同じ導出。
 * 変更時は両方揃えること)。runID 先頭6桁が yyyyMM で無い(不正な runID)場合は "unknown" 配下。
 */
function runDirFor(workspaceRoot: string, project: string, runID: string): string {
  const runsDir = path.join(workspaceRoot, "Projects", project, "results", "runs");
  if (runID.length < 6) {
    return path.join(runsDir, "unknown", runID);
  }
  const month = `${runID.slice(0, 4)}-${runID.slice(4, 6)}`;
  return path.join(runsDir, month, runID);
}

/** recordings/index.json のある run を新しい順(runID 降順)に列挙する。上限 SESSION_LIMIT 件。 */
export async function listRecordingSessions(workspaceRoot: string): Promise<RecordingSessionSummary[]> {
  const projectsDir = path.join(workspaceRoot, "Projects");
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
        const metaRaw = await readJson(path.join(runDir, "run.json"));
        const meta = isRecord(metaRaw) ? metaRaw : null;
        sessions.push({
          project,
          runID,
          startedAt: stringField(meta, "startedAt") ?? runID,
          passed: numberField(meta, "passed") ?? null,
          failed: numberField(meta, "failed") ?? null,
        });
      }
    }
  }
  sessions.sort((a, b) => (a.runID < b.runID ? 1 : a.runID > b.runID ? -1 : 0));
  return sessions.slice(0, SESSION_LIMIT);
}

export interface RecordingSessionDetailRaw {
  readonly runDir: string;
  readonly index: RecordingIndex;
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
  return { runDir, index: indexRaw, scenarios };
}
