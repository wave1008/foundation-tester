// watcher.ts
// Projects/*/Scenarios/**/*.swift の変更を監視し、デバウンスしてから onChanged を呼ぶ。
// TestRun/デバッグ実行中は setSuspended(true) で refresh を保留できるようにしておく
// (実行結果と入れ替わりでツリーが再構築されるのを防ぐため。実際に suspend するかどうかの
// 判断は後続フェーズの runHandler/debugAdapter が行う)。

import * as vscode from "vscode";

const DEFAULT_DEBOUNCE_MS = 800;
const WATCH_GLOB = "Projects/*/Scenarios/**/*.swift";

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

  /**
   * true にすると以後の変更検知で refresh をスケジュールせず保留する。
   * false に戻した時点で保留分があれば、まとめて1回だけ refresh をスケジュールする。
   */
  setSuspended(suspended: boolean): void {
    this.suspended = suspended;
    if (!suspended && this.pendingWhileSuspended) {
      this.pendingWhileSuspended = false;
      this.scheduleRefresh();
    }
  }

  /**
   * onChanged に加えて変更通知を受け取りたい場合に登録する(ステップ一覧のキャッシュ invalidate 等)。
   * onChanged と同じタイミング(デバウンス後)で呼ばれる。
   */
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
