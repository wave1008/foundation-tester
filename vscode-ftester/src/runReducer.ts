// runReducer.ts
// ftester api run の NDJSON イベント(RunEvent)を、vscode.TestRun に反映すべき
// アクション列(RunAction[])に変換する。vscode モジュールに一切依存しない純粋なロジックで、
// runHandler.ts がこのアクション列を vscode API(run.started/appendOutput/failed/passed/end)へ
// 適用する。
//
// 状態(RunReducerState)は呼び出し側が createRunReducerState() で生成し、
// reduceRunEvent() の呼び出しごとに使い回す(内部で書き換える)。時刻は呼び出し側から
// nowMs として注入する(scenarioStarted〜scenarioFinished の実測に使うだけで、
// このモジュール自身は Date.now() 等を呼ばない)。
//
// アイコンは Sources/FTCore/RunOrchestrator.swift の RunLogFormatter と揃えている
// (✅ 成功 / ❌ 失敗 / ⚠️ スキップ / 🔧 自己修復 / 💡 修正提案 / ▶ 開始 / ⏸ 一時停止)。

import { isRunEvent, type RunEvent, type WorkerInfo } from "./model";

/** 出力・失敗メッセージに添えるソース位置。file はリポジトリルート相対、line は1起点。 */
export interface RunLocation {
  file: string;
  line: number;
}

/** run.failed に渡す 1 件分の失敗メッセージ。 */
export interface RunFailureMessage {
  text: string;
  location?: RunLocation;
}

/** runHandler.ts が vscode API へ適用するアクション。 */
export type RunAction =
  | { type: "started"; scenario: string }
  | { type: "output"; text: string; scenario?: string; location?: RunLocation; worker?: string }
  | { type: "passed"; scenario: string; durationMs: number }
  | { type: "failed"; scenario: string; messages: RunFailureMessage[]; durationMs: number }
  | { type: "end"; passed: number; failed: number }
  /** 並列実行(--profile)時、runStarted 直後の workersReady から発生する。 */
  | { type: "workers"; workers: WorkerInfo[] };

interface ScenarioProgress {
  startedAtMs: number;
  messages: RunFailureMessage[];
}

/** reduceRunEvent が使い回す内部状態。中身は runHandler.ts からは触らない。 */
export interface RunReducerState {
  scenarios: Map<string, ScenarioProgress>;
}

export function createRunReducerState(): RunReducerState {
  return { scenarios: new Map() };
}

/**
 * ステップの status → アイコンの対応。runLaneModel.ts(デバイスモニターのログレーン)からも
 * 同じアイコンを再利用する(見た目の一貫性のため)。
 */
export const STATUS_MARK: Record<string, string> = {
  passed: "✅",
  passedViaFallback: "✅",
  healed: "🔧",
  failed: "❌",
  skipped: "⚠️",
};

/**
 * RunReducerState を1イベント分進め、適用すべきアクション列を返す。
 * value は NdjsonParser が JSON.parse しただけの unknown 値(非JSON行はそもそも
 * onNonJson 側に回るためここには来ないが、壊れた/未知の kind の JSON が来ても
 * isRunEvent が false を返すのでアクション無しで安全に無視する)。
 */
export function reduceRunEvent(
  state: RunReducerState,
  value: unknown,
  nowMs: number,
): { state: RunReducerState; actions: RunAction[] } {
  if (!isRunEvent(value)) {
    return { state, actions: [] };
  }
  return { state, actions: actionsFor(state, value, nowMs) };
}

function actionsFor(state: RunReducerState, event: RunEvent, nowMs: number): RunAction[] {
  switch (event.kind) {
    case "runStarted":
      return [{ type: "output", text: `▶ 実行開始(${String(event.total)}件)` }];

    case "workersReady":
      // 並列実行(--profile)時のみ発生。以降の全イベントに worker が付く合図。
      return [{ type: "workers", workers: event.workers }];

    case "scenarioStarted": {
      state.scenarios.set(event.scenario, { startedAtMs: nowMs, messages: [] });
      const label = event.title ? `${event.title} [${event.scenario}]` : event.scenario;
      return [
        { type: "started", scenario: event.scenario },
        { type: "output", scenario: event.scenario, text: `▶ ${label}`, worker: event.worker },
      ];
    }

    case "sceneStarted": {
      const scene = event.scene ?? 0;
      const title = event.sceneTitle ?? "";
      return [
        {
          type: "output",
          scenario: event.scenario,
          text: `  シーン${String(scene)}: ${title}`,
          worker: event.worker,
        },
      ];
    }

    case "step":
      return stepActions(state, event);

    case "sceneFinished": {
      const scene = event.scene ?? 0;
      const mark = event.passed ? "✅" : "❌";
      const label = event.passed ? "成功" : "失敗";
      return [
        {
          type: "output",
          scenario: event.scenario,
          text: `  ${mark} シーン${String(scene)} ${label}`,
          worker: event.worker,
        },
      ];
    }

    case "fixSuggestion": {
      const text = `  💡 修正提案: ${event.detail ?? event.description ?? ""}`;
      const location = toLocation(event.file, event.line);
      const actions: RunAction[] = [
        { type: "output", scenario: event.scenario, text, location, worker: event.worker },
      ];
      if (event.oldSelector && event.newSelector) {
        actions.push({
          type: "output",
          scenario: event.scenario,
          text: `     ${event.oldSelector} → ${event.newSelector}`,
          location,
          worker: event.worker,
        });
      }
      return actions;
    }

    case "paused":
      // --debug 実行専用のイベント。このリポジトリの実行プロファイルは --debug を付与しないため
      // 通常は発生しないが、念のため出力だけして無視する(デバッグアダプタは後続フェーズで対応)。
      // --debug は並列実行(--profile 非dry-run)と排他のため worker は付与されない。
      return [
        {
          type: "output",
          scenario: event.scenario,
          text: `  ⏸ 一時停止: ${event.description ?? ""}`,
          location: toLocation(event.file, event.line),
        },
      ];

    case "scenarioFinished":
      return scenarioFinishedActions(state, event, nowMs);

    case "log": {
      const message = event.message ?? "";
      if (message.length === 0) {
        return [];
      }
      return [{ type: "output", scenario: event.scenario, text: `  ${message}`, worker: event.worker }];
    }

    case "runFinished":
      return [
        {
          type: "output",
          text: `■ 完了: 成功 ${String(event.passed)} / 失敗 ${String(event.failed)}`,
        },
        { type: "end", passed: event.passed, failed: event.failed },
      ];
  }
}

function stepActions(
  state: RunReducerState,
  event: Extract<RunEvent, { kind: "step" }>,
): RunAction[] {
  const mark = STATUS_MARK[event.status] ?? "•";
  const index = event.index != null ? `${String(event.index)}. ` : "";
  const location = toLocation(event.file, event.line);
  const actions: RunAction[] = [
    {
      type: "output",
      scenario: event.scenario,
      text: `  ${mark} ${index}${event.description ?? ""}`,
      location,
      worker: event.worker,
    },
  ];

  if (event.detail) {
    let detailLine: string;
    switch (event.status) {
      case "passedViaFallback":
        detailLine = `     フォールバック: ${event.detail}`;
        break;
      case "healed":
        detailLine = `     自己修復: ${event.detail}`;
        break;
      case "skipped":
        detailLine = `     スキップ理由: ${event.detail}`;
        break;
      default:
        detailLine = `     ${event.detail}`;
    }
    actions.push({
      type: "output",
      scenario: event.scenario,
      text: detailLine,
      location,
      worker: event.worker,
    });
  }

  if (event.status === "failed") {
    const progress = state.scenarios.get(event.scenario);
    const text = event.detail ? `${event.description ?? ""}\n${event.detail}` : (event.description ?? "失敗しました");
    const message: RunFailureMessage = { text, location };
    if (progress) {
      progress.messages.push(message);
    } else {
      // scenarioStarted を観測する前に step が来ることは無い想定だが、
      // 念のため見失わないよう即席の progress を用意しておく
      state.scenarios.set(event.scenario, { startedAtMs: 0, messages: [message] });
    }
  }

  return actions;
}

function scenarioFinishedActions(
  state: RunReducerState,
  event: Extract<RunEvent, { kind: "scenarioFinished" }>,
  nowMs: number,
): RunAction[] {
  const progress = state.scenarios.get(event.scenario);
  const durationMs = progress ? Math.max(0, nowMs - progress.startedAtMs) : 0;
  state.scenarios.delete(event.scenario);

  if (event.passed) {
    return [
      {
        type: "output",
        scenario: event.scenario,
        text: `  ✅ 成功 (${String(durationMs)}ms)`,
        worker: event.worker,
      },
      { type: "passed", scenario: event.scenario, durationMs },
    ];
  }

  const reportSuffix = event.reportPath ? ` — レポート: ${event.reportPath}` : "";
  const messages =
    progress && progress.messages.length > 0
      ? progress.messages
      : [{ text: `シナリオが失敗しました${event.reportPath ? `(レポート: ${event.reportPath})` : ""}` }];

  return [
    { type: "output", scenario: event.scenario, text: `  ❌ 失敗${reportSuffix}`, worker: event.worker },
    { type: "failed", scenario: event.scenario, messages, durationMs },
  ];
}

function toLocation(file: string | undefined, line: number | undefined): RunLocation | undefined {
  if (!file || line == null) {
    return undefined;
  }
  return { file, line };
}
