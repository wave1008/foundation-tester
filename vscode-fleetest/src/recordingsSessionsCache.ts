// recordingsSessionsCache.ts
// テストセッション一覧の前回結果を workspaceState に置く(リロード後の初回表示に使う。
// 使い方は monitorRecordingsController.ts の refreshSessions)。

import type * as vscode from "vscode";
import type { RecordingsSessionsCache } from "./monitorRecordingsController";
import type { RecordingSessionSummary } from "./recordingsStore";

const STATE_KEY = "monitor.recordingsSessionsCache";
/** RecordingSessionSummary の形を変えたら上げる(古い形の控えは読まずに捨てる)。 */
const CACHE_VERSION = 1;

interface StoredCache {
  readonly version: number;
  readonly entries: Record<string, readonly RecordingSessionSummary[]>;
}

function readStored(state: vscode.Memento): Record<string, readonly RecordingSessionSummary[]> {
  const stored = state.get<StoredCache>(STATE_KEY);
  if (stored === undefined || stored === null || stored.version !== CACHE_VERSION
    || typeof stored.entries !== "object" || stored.entries === null) {
    return {};
  }
  return stored.entries;
}

function isSummaryList(value: unknown): value is readonly RecordingSessionSummary[] {
  return Array.isArray(value) && value.every((item) =>
    typeof item === "object" && item !== null
    && typeof (item as { project?: unknown }).project === "string"
    && typeof (item as { runID?: unknown }).runID === "string");
}

export function workspaceRecordingsSessionsCache(state: vscode.Memento): RecordingsSessionsCache {
  return {
    get: (key) => {
      const value: unknown = readStored(state)[key];
      return isSummaryList(value) ? value : undefined;
    },
    set: (key, sessions) => {
      const entries = { ...readStored(state), [key]: sessions };
      void state.update(STATE_KEY, { version: CACHE_VERSION, entries } satisfies StoredCache);
    },
  };
}
