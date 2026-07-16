// watcher.ts
// Projects/*/Scenarios/**/*.swift の変更を監視し、デバウンスしてから onChanged を呼ぶ。
// setSuspended(true) 中は refresh を保留する(runHandler/debugAdapter がテスト実行結果と
// ツリー再構築の競合を避けるために使う)。

import * as vscode from "vscode";

const DEFAULT_DEBOUNCE_MS = 800;
/** シナリオファイルの glob(reportCodeLens.ts の CodeLens 対象パターンと同一にすること)。 */
export const WATCH_GLOB = "Projects/*/Scenarios/**/*.swift";

export class ScenarioFileWatcher implements vscode.Disposable {
  private readonly watcher: vscode.FileSystemWatcher;
  private readonly disposables: vscode.Disposable[] = [];
  private readonly changeListeners: Array<() => void> = [];
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private suspended = false;
  private pendingWhileSuspended = false;

  constructor(
    workspaceRoot: string,
    private readonly onChanged: () => void,
    private readonly debounceMs: number = DEFAULT_DEBOUNCE_MS,
  ) {
    const pattern = new vscode.RelativePattern(workspaceRoot, WATCH_GLOB);
    this.watcher = vscode.workspace.createFileSystemWatcher(pattern);
    this.disposables.push(
      this.watcher,
      this.watcher.onDidCreate(() => this.scheduleRefresh()),
      this.watcher.onDidChange(() => this.scheduleRefresh()),
      this.watcher.onDidDelete(() => this.scheduleRefresh()),
    );
  }

  /** false に戻した時点で保留分があれば、まとめて1回だけ refresh をスケジュールする。 */
  setSuspended(suspended: boolean): void {
    this.suspended = suspended;
    if (!suspended && this.pendingWhileSuspended) {
      this.pendingWhileSuspended = false;
      this.scheduleRefresh();
    }
  }

  /** onChanged と同じタイミング(デバウンス後)で呼ばれる追加リスナー(ステップ一覧キャッシュ invalidate 等)。 */
  addChangeListener(listener: () => void): vscode.Disposable {
    this.changeListeners.push(listener);
    return {
      dispose: () => {
        const index = this.changeListeners.indexOf(listener);
        if (index !== -1) {
          this.changeListeners.splice(index, 1);
        }
      },
    };
  }

  private scheduleRefresh(): void {
    if (this.suspended) {
      this.pendingWhileSuspended = true;
      return;
    }
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      this.onChanged();
      for (const listener of this.changeListeners) {
        listener();
      }
    }, this.debounceMs);
  }

  dispose(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = undefined;
    }
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
  }
}
