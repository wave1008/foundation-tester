// runLaneModel.ts
// デバイスモニターの「ログレーン」表示用の純粋なロジック。RunEventBus 経由で届く生の
// RunEvent 列を、レーン構成(workersReady → タイル単位のレーン)・レーン本文の行・
// ワーカーの実行中状態(タイルの「実行中」バッジ)に変換する。
//
// vscode/webview に一切依存しない(monitorPanel.ts からも test/runLaneModel.test.mjs からも
// 同じロジックを使えるようにするため。runReducer.ts と同じ方針)。
// runReducer.ts(TestRun への反映)とは別の状態・関心事を持つ独立したモジュールだが、
// アイコン表現(✅❌⚠️💡▶等)は STATUS_MARK を再利用して見た目を揃える。

import { STATUS_MARK } from "./runReducer";
import type { RunEvent, WorkerInfo } from "./model";

/** worker フィールドが無いイベント(逐次実行 = 非プロファイル/dry-run/デバッグ)をまとめるレーン。 */
export const OVERALL_LANE_ID = "__overall__";
export const OVERALL_LANE_NAME = "全体";

/** レーンごとに保持する最大行数。超えた分は古い行から捨てる。 */
export const MAX_LANE_LINES = 500;

export interface LaneInfo {
  readonly id: string;
  readonly name: string;
  readonly platform: "ios" | "android" | undefined;
  readonly detail: string | undefined;
}

/** webview へ転送するレーン更新アクション。webview はこれをそのまま描画に反映する。 */
export type LaneAction =
  /** 新しい実行の開始(runStarted)。レーン・行・実行中状態を全てクリアする合図。 */
  | { readonly type: "cleared" }
  /** 並列実行(workersReady)。この構成でレーンを作り直す。 */
  | { readonly type: "lanesConfigured"; readonly lanes: readonly LaneInfo[] }
  /** レーンへの1行追加。 */
  | { readonly type: "line"; readonly laneId: string; readonly text: string }
  /** ワーカーの実行中状態の変化(タイルの「実行中」バッジに反映)。 */
  | { readonly type: "workerRunning"; readonly workerId: string; readonly running: boolean }
  /** runFinished。全体の完了表示に使う。 */
  | { readonly type: "runFinished"; readonly passed: number; readonly failed: number };

interface LaneEntry {
  info: LaneInfo;
  lines: string[];
}

interface ScenarioTiming {
  readonly worker: string | undefined;
  readonly startedAtMs: number;
}

/** reduceLaneEvent が使い回す内部状態。中身は monitorPanel.ts からは直接触らない。 */
export interface RunLaneState {
  lanes: Map<string, LaneEntry>;
  runningWorkers: Set<string>;
  scenarioTimings: Map<string, ScenarioTiming>;
}

export function createRunLaneState(): RunLaneState {
  return { lanes: new Map(), runningWorkers: new Set(), scenarioTimings: new Map() };
}

/** 現在の状態をそのまま(webview 再生成時のハイドレーション用に)スナップショットする。 */
export interface LaneHydrateSnapshot {
  readonly lanes: readonly LaneInfo[];
  readonly linesByLane: Readonly<Record<string, readonly string[]>>;
  readonly runningWorkers: readonly string[];
}

export function snapshotRunLaneState(state: RunLaneState): LaneHydrateSnapshot {
  const linesByLane: Record<string, readonly string[]> = {};
  const lanes: LaneInfo[] = [];
  for (const [id, entry] of state.lanes) {
    lanes.push(entry.info);
    linesByLane[id] = [...entry.lines];
  }
  return { lanes, linesByLane, runningWorkers: [...state.runningWorkers] };
}

// ---- extension → webview メッセージ(monitorPanel.ts が postMessage する形)---------------

/** レーンセクション自体の表示/非表示(実行が始まったら表示する)。 */
export interface LaneSectionVisibleMessage {
  readonly type: "laneSectionVisible";
  readonly visible: boolean;
}

/** 1件の LaneAction をそのまま webview へ転送する。 */
export interface RunEventToWebviewMessage {
  readonly type: "runEvent";
  readonly action: LaneAction;
}

/** webview(パネル)を新規作成したとき、現在のレーン状態を丸ごと渡す(履歴の再現用)。 */
export interface LaneHydrateMessage {
  readonly type: "laneHydrate";
  readonly snapshot: LaneHydrateSnapshot;
}

export type RunLaneToWebviewMessage =
  | LaneSectionVisibleMessage
  | RunEventToWebviewMessage
  | LaneHydrateMessage;

function laneIdOf(event: RunEvent): string {
  const worker = (event as { worker?: string }).worker;
  return worker ?? OVERALL_LANE_ID;
}

function ensureLane(state: RunLaneState, laneId: string): LaneEntry {
  const existing = state.lanes.get(laneId);
  if (existing) {
    return existing;
  }
  const info: LaneInfo =
    laneId === OVERALL_LANE_ID
      ? { id: OVERALL_LANE_ID, name: OVERALL_LANE_NAME, platform: undefined, detail: undefined }
      : { id: laneId, name: laneId, platform: undefined, detail: undefined };
  const entry: LaneEntry = { info, lines: [] };
  state.lanes.set(laneId, entry);
  return entry;
}

function pushLine(state: RunLaneState, laneId: string, text: string): LaneAction[] {
  const lane = ensureLane(state, laneId);
  lane.lines.push(text);
  if (lane.lines.length > MAX_LANE_LINES) {
    lane.lines.shift();
  }
  return [{ type: "line", laneId, text }];
}

/** runStarted 受信時にレーン状態を全クリアする(新しい実行の開始)。 */
export function resetRunLaneState(state: RunLaneState): LaneAction[] {
  state.lanes.clear();
  state.runningWorkers.clear();
  state.scenarioTimings.clear();
  return [{ type: "cleared" }];
}

/** workersReady 受信時にレーン構成を作り直す。 */
function applyWorkers(state: RunLaneState, workers: readonly WorkerInfo[]): LaneAction[] {
  state.lanes.clear();
  const lanes: LaneInfo[] = [];
  for (const worker of workers) {
    const info: LaneInfo = {
      id: worker.id,
      name: worker.name,
      platform: worker.platform,
      detail: worker.detail,
    };
    state.lanes.set(worker.id, { info, lines: [] });
    lanes.push(info);
  }
  return [{ type: "lanesConfigured", lanes }];
}

/**
 * プロセス終了(runEnded)時、runFinished を受信しないまま終わった場合の後始末。
 * まだ「実行中」のワーカーが残っていれば強制的に解除する(runFinished 済みなら何もしない)。
 */
export function forceEndRunLaneState(state: RunLaneState): LaneAction[] {
  const actions: LaneAction[] = [];
  for (const workerId of state.runningWorkers) {
    actions.push({ type: "workerRunning", workerId, running: false });
  }
  state.runningWorkers.clear();
  return actions;
}

/** RunEvent 1件をレーン用アクション列に変換する(runReducer.reduceRunEvent とは別系統の状態)。 */
export function reduceLaneEvent(state: RunLaneState, event: RunEvent, nowMs: number): LaneAction[] {
  switch (event.kind) {
    case "runStarted":
      return resetRunLaneState(state);

    case "workersReady":
      return applyWorkers(state, event.workers);

    case "scenarioStarted": {
      state.scenarioTimings.set(event.scenario, { worker: event.worker, startedAtMs: nowMs });
      const actions: LaneAction[] = [];
      if (event.worker) {
        state.runningWorkers.add(event.worker);
        actions.push({ type: "workerRunning", workerId: event.worker, running: true });
      }
      const label = event.title ? `${event.title} [${event.scenario}]` : event.scenario;
      actions.push(...pushLine(state, laneIdOf(event), `▶ ${label}`));
      return actions;
    }

    case "sceneStarted": {
      const scene = event.scene ?? 0;
      return pushLine(state, laneIdOf(event), `  シーン${String(scene)}: ${event.sceneTitle ?? ""}`);
    }

    case "step": {
      const mark = STATUS_MARK[event.status] ?? "•";
      const index = event.index != null ? `${String(event.index)}. ` : "";
      const actions = pushLine(state, laneIdOf(event), `  ${mark} ${index}${event.description ?? ""}`);
      if (event.detail) {
        actions.push(...pushLine(state, laneIdOf(event), `     ${event.detail}`));
      }
      return actions;
    }

    case "sceneFinished": {
      const scene = event.scene ?? 0;
      const mark = event.passed ? "✅" : "❌";
      const label = event.passed ? "成功" : "失敗";
      return pushLine(state, laneIdOf(event), `  ${mark} シーン${String(scene)} ${label}`);
    }

    case "fixSuggestion": {
      const actions = pushLine(
        state,
        laneIdOf(event),
        `  💡 修正提案: ${event.detail ?? event.description ?? ""}`,
      );
      if (event.oldSelector && event.newSelector) {
        actions.push(
          ...pushLine(state, laneIdOf(event), `     ${event.oldSelector} → ${event.newSelector}`),
        );
      }
      return actions;
    }

    case "paused":
      // --debug 実行専用(並列実行とは排他)。レーン表示は不要。
      return [];

    case "scenarioFinished": {
      const laneId = laneIdOf(event);
      const timing = state.scenarioTimings.get(event.scenario);
      state.scenarioTimings.delete(event.scenario);
      const actions: LaneAction[] = [];
      if (event.passed) {
        const durationMs = timing ? Math.max(0, nowMs - timing.startedAtMs) : undefined;
        const suffix = durationMs != null ? ` (${String(durationMs)}ms)` : "";
        actions.push(...pushLine(state, laneId, `  ✅ 成功${suffix}`));
      } else {
        const reportSuffix = event.reportPath ? ` — レポート: ${event.reportPath}` : "";
        actions.push(...pushLine(state, laneId, `  ❌ 失敗${reportSuffix}`));
      }
      if (event.worker && state.runningWorkers.has(event.worker)) {
        state.runningWorkers.delete(event.worker);
        actions.push({ type: "workerRunning", workerId: event.worker, running: false });
      }
      return actions;
    }

    case "log": {
      const message = event.message ?? "";
      if (message.length === 0) {
        return [];
      }
      return pushLine(state, laneIdOf(event), `  ${message}`);
    }

    case "runFinished": {
      const actions: LaneAction[] = [...forceEndRunLaneState(state)];
      actions.push({ type: "runFinished", passed: event.passed, failed: event.failed });
      return actions;
    }
  }
}
