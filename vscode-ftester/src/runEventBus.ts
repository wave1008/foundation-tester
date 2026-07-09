// runEventBus.ts
// 実行(`ftester api run`)の生 NDJSON イベント(検証済み RunEvent)と、実行自体の開始/終了を
// 複数の購読者へ配信するための小さな pub/sub。vscode モジュールに一切依存しない。
//
// runHandler.ts(Test Explorer への反映)と monitorPanel.ts(ログレーン表示)は、
// どちらも同じ `ftester api run` の出力を別の目的で消費する。この2つを直接結合させず、
// extension.ts で生成した1つの RunEventBus インスタンスを両方に注入することで疎結合にする。
//
// runId は beginRun() のたびに採番される(同時に2つ以上の実行は無い前提。cli.ts の
// 直列実行キューにより `ftester api run` は同時に1本しか動かないため、判別自体は不要だが、
// 将来的な多重実行や取り違え防止のため念のため付与しておく)。

import type { RunEvent } from "./model";

export type RunBusMessage =
  | { readonly type: "runStarted"; readonly runId: number }
  | { readonly type: "event"; readonly runId: number; readonly event: RunEvent }
  | { readonly type: "runEnded"; readonly runId: number };

export type RunBusListener = (message: RunBusMessage) => void;

export class RunEventBus {
  private readonly listeners = new Set<RunBusListener>();
  private nextRunId = 1;

  /** 購読を開始する。戻り値の関数を呼ぶと購読解除できる。 */
  subscribe(listener: RunBusListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** 新しい実行の開始を全購読者に通知し、以後の publish/endRun に使う runId を返す。 */
  beginRun(): number {
    const runId = this.nextRunId;
    this.nextRunId += 1;
    this.emit({ type: "runStarted", runId });
    return runId;
  }

  /** 検証済みの RunEvent(生イベント)を配信する。 */
  publish(runId: number, event: RunEvent): void {
    this.emit({ type: "event", runId, event });
  }

  /** 実行の終了(正常/異常問わず)を全購読者に通知する。 */
  endRun(runId: number): void {
    this.emit({ type: "runEnded", runId });
  }

  private emit(message: RunBusMessage): void {
    for (const listener of this.listeners) {
      listener(message);
    }
  }
}
