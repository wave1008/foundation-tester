// runEventBus.ts
// `ftester api run` の NDJSON イベントを runHandler.ts(Test Explorer反映)と
// monitorPanel.ts(ログレーン表示)の両方へ配信する pub/sub。vscode モジュールに依存しない。
// extension.ts で1つだけ生成し両方に注入することで両者を疎結合にする。
//
// runId は beginRun() ごとに採番。cli.ts の直列キューにより同時実行は1本のみで判別は不要だが、
// 将来の多重実行対策として残している(削除しないこと)。

import type { RunEvent } from "./model";

export type RunBusMessage =
  | { readonly type: "runStarted"; readonly runId: number; readonly isDryRun: boolean }
  | { readonly type: "event"; readonly runId: number; readonly event: RunEvent }
  | { readonly type: "runEnded"; readonly runId: number };

export type RunBusListener = (message: RunBusMessage) => void;

export class RunEventBus {
  private readonly listeners = new Set<RunBusListener>();
  private nextRunId = 1;

  subscribe(listener: RunBusListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** isDryRun は healReviewPanel.ts の HealFixCollector が dry-run 実行を除外する判定に使う。 */
  beginRun(isDryRun = false): number {
    const runId = this.nextRunId;
    this.nextRunId += 1;
    this.emit({ type: "runStarted", runId, isDryRun });
    return runId;
  }

  publish(runId: number, event: RunEvent): void {
    this.emit({ type: "event", runId, event });
  }

  endRun(runId: number): void {
    this.emit({ type: "runEnded", runId });
  }

  private emit(message: RunBusMessage): void {
    for (const listener of this.listeners) {
      listener(message);
    }
  }
}
