// healModel.ts
// vscode 非依存。HealFixCollector は healNotice.ts が「実行終了時に1件以上あれば通知する」判定に使う。

import type { FixSuggestionEvent, RunEvent } from "./model";

/** 1件の自己修復候補(RunEventBus の fixSuggestion イベントから収集したもの)。 */
export interface HealFix {
  readonly scenarioID: string;
  /** リポジトリルート相対パス(イベントのまま。絶対パスの場合もある)。 */
  readonly file: string;
  readonly line: number;
  readonly oldSelector: string;
  readonly newSelector: string;
  /** 提案文(detail が無ければ description。どちらも無ければ空文字列)。 */
  readonly message: string;
  /** 対象コマンドの description(例: tap "旧セレクタ")。id には含めない。 */
  readonly command: string | undefined;
}

function healFixId(fix: Pick<HealFix, "scenarioID" | "file" | "line" | "oldSelector">): string {
  return `${fix.scenarioID}|${fix.file}:${String(fix.line)}|${fix.oldSelector}`;
}

function fixFromFixSuggestion(event: FixSuggestionEvent): HealFix | undefined {
  if (
    typeof event.scenario !== "string" ||
    event.scenario.length === 0 ||
    typeof event.file !== "string" ||
    event.file.length === 0 ||
    typeof event.line !== "number" ||
    typeof event.oldSelector !== "string" ||
    event.oldSelector.length === 0 ||
    typeof event.newSelector !== "string" ||
    event.newSelector.length === 0
  ) {
    return undefined;
  }
  return {
    scenarioID: event.scenario,
    file: event.file,
    line: event.line,
    oldSelector: event.oldSelector,
    newSelector: event.newSelector,
    message: event.detail ?? event.description ?? "",
    command: event.description,
  };
}

/**
 * fixSuggestion イベントを収集する状態クラス。begin(isDryRun) で実行開始ごとにクリアし、
 * isDryRun なら以降 collect() は無視する。collect() は id(healFixId)で重複排除(後勝ち)。
 */
export class HealFixCollector {
  private readonly collected = new Map<string, HealFix>();
  private dryRun = false;

  begin(isDryRun: boolean): void {
    this.collected.clear();
    this.dryRun = isDryRun;
  }

  collect(event: RunEvent): void {
    if (this.dryRun || event.kind !== "fixSuggestion") {
      return;
    }
    const fix = fixFromFixSuggestion(event);
    if (!fix) {
      return;
    }
    this.collected.set(healFixId(fix), fix);
  }

  list(): HealFix[] {
    return [...this.collected.values()];
  }

  isEmpty(): boolean {
    return this.collected.size === 0;
  }
}

/** 候補の件数(同じ file・line・旧セレクタ・新セレクタは1件。シナリオ違いで同じ行を直した分を重ねて数えない)。 */
export function countDistinctFixes(fixes: readonly HealFix[]): number {
  return new Set(fixes.map((fix) => JSON.stringify([fix.file, fix.line, fix.oldSelector, fix.newSelector]))).size;
}
