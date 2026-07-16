// lastResultsSync.ts
// last-results ディレクトリ(CLI が書く。lastResults.ts 参照)への書き込みをターミナルからの
// `ftester run` 実行時にも Test Explorer アイコンへ反映する(runHandler.ts の GUI 実行は
// 自前でツリーへ反映済みなので対象外)。GUI 実行中(isGuiRunActive)は tick を丸ごと skip する
// (appliedSnapshot は更新しない。ストアは増える一方なので GUI 実行終了後の次 tick で追いつく)。

import * as fs from "node:fs";
import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import { lastResultsDir, readAllResults, type ResultState } from "./lastResults";
import { findLatestReport, reportsDir } from "./scenarioReports";

const DEBOUNCE_MS = 1000;
const DIR_RETRY_MS = 10000;
const INITIAL_REFLECT_POLL_MS = 2000;
const INITIAL_REFLECT_MAX_ATTEMPTS = 15;

export interface LastResultsSyncDeps {
  controller: vscode.TestController;
  workspaceRoot: string;
  getConfig: () => FtesterConfig;
  isGuiRunActive: () => boolean;
  outputChannel: vscode.OutputChannel;
}

/** current のうち previous と状態が異なる(または previous に無い)エントリのみ返す。
 * previous にあって current に無い id は報告しない(last-results は増える一方の運用のため)。 */
export function diffLastResults(
  current: Map<string, ResultState>,
  previous: Map<string, ResultState>,
): Array<{ id: string; state: ResultState }> {
  const changed: Array<{ id: string; state: ResultState }> = [];
  for (const [id, state] of current) {
    if (previous.get(id) !== state) {
      changed.push({ id, state });
    }
  }
  return changed;
}

function findLeaf(items: vscode.TestItemCollection, id: string): vscode.TestItem | undefined {
  let found: vscode.TestItem | undefined;
  items.forEach((item) => {
    if (found) {
      return;
    }
    if (item.id === id) {
      found = item;
    } else if (item.children.size > 0) {
      found = findLeaf(item.children, id);
    }
  });
  return found;
}

/** レポートが見つかれば ftester.openScenarioReport(runHandler.ts)へのリンク付きメッセージ、
 * 無ければ従来通りのプレーンテキスト。location(テスト宣言位置)が無いとエディタの
 * インライン peek に出ず Test Results パネル限定になる(テストをクリックした時にリンクが
 * 見えない)ため、item の uri/range があれば付ける。 */
function buildFailedMessage(
  workspaceRoot: string, project: string, item: vscode.TestItem,
): vscode.TestMessage {
  const reportPath = findLatestReport(reportsDir(workspaceRoot, project), item.id);
  let message: vscode.TestMessage;
  if (!reportPath) {
    message = new vscode.TestMessage("CLI 実行で失敗(詳細はレポート参照)");
  } else {
    const args = encodeURIComponent(JSON.stringify([item.id]));
    const markdown = new vscode.MarkdownString(
      `CLI 実行で失敗 — [レポートを開く](command:ftester.openScenarioReport?${args})`,
    );
    markdown.isTrusted = { enabledCommands: ["ftester.openScenarioReport"] };
    message = new vscode.TestMessage(markdown);
  }
  if (item.uri && item.range) {
    message.location = new vscode.Location(item.uri, item.range);
  }
  return message;
}

/** leaf の定義は runHandler.ts の resolveTargets/addSubtree と同じ(children.size === 0)。 */
function hasAnyLeaf(items: vscode.TestItemCollection): boolean {
  let has = false;
  items.forEach((item) => {
    if (has) {
      return;
    }
    has = item.children.size === 0 || hasAnyLeaf(item.children);
  });
  return has;
}

export function registerLastResultsSync(deps: LastResultsSyncDeps): vscode.Disposable {
  const { controller, workspaceRoot, getConfig, isGuiRunActive, outputChannel } = deps;

  let appliedSnapshot: Map<string, ResultState> = new Map();
  let fsWatcher: fs.FSWatcher | undefined;
  let dirRetryTimer: ReturnType<typeof setInterval> | undefined;
  let debounceTimer: ReturnType<typeof setTimeout> | undefined;
  let initialReflectTimer: ReturnType<typeof setInterval> | undefined;

  const applyTick = (): void => {
    if (isGuiRunActive()) {
      return; // 今ツリーを触っているのは runHandler.ts の本物の TestRun。次 tick で追いつく。
    }
    const resolution = resolveProjectName(workspaceRoot, getConfig());
    if (resolution.kind !== "resolved") {
      return;
    }
    const current = readAllResults(lastResultsDir(workspaceRoot, resolution.project));
    const changed = diffLastResults(current, appliedSnapshot);
    appliedSnapshot = current;
    if (changed.length === 0) {
      return;
    }
    const matches: Array<{ item: vscode.TestItem; state: ResultState }> = [];
    for (const { id, state } of changed) {
      const item = findLeaf(controller.items, id);
      if (item) {
        matches.push({ item, state });
      }
    }
    if (matches.length === 0) {
      return;
    }
    const run = controller.createTestRun(new vscode.TestRunRequest(), "CLI実行結果", false);
    for (const { item, state } of matches) {
      if (state === "passed") {
        run.passed(item);
      } else {
        run.failed(item, buildFailedMessage(workspaceRoot, resolution.project, item));
      }
    }
    run.end();
    outputChannel.appendLine(`[lastResultsSync] 反映 ${matches.length}件`);
  };

  const scheduleTick = (): void => {
    if (debounceTimer) {
      clearTimeout(debounceTimer);
    }
    debounceTimer = setTimeout(() => {
      debounceTimer = undefined;
      applyTick();
    }, DEBOUNCE_MS);
  };

  // last-results/<project>/ は初回 CLI 実行まで存在せず fs.watch が ENOENT で即例外を投げる
  // (project 未解決の間も同様に待つ)。存在するまで DIR_RETRY_MS 間隔で watch 登録をリトライする。
  const tryStartWatching = (): void => {
    const resolution = resolveProjectName(workspaceRoot, getConfig());
    if (resolution.kind !== "resolved") {
      return;
    }
    try {
      fsWatcher = fs.watch(lastResultsDir(workspaceRoot, resolution.project), () => scheduleTick());
      if (dirRetryTimer) {
        clearInterval(dirRetryTimer);
        dirRetryTimer = undefined;
      }
    } catch {
      // ディレクトリ未作成。dirRetryTimer が次回リトライする。
    }
  };
  tryStartWatching();
  if (!fsWatcher) {
    dirRetryTimer = setInterval(tryStartWatching, DIR_RETRY_MS);
  }

  // Reload Window 直後、appliedSnapshot は空だが fs.watch は変化検知のみでトリガーせず
  // 登録時点の既存結果を拾わない(ファイルが変化しない限り黙って古いアイコンのまま)。
  // testTree.refresh() は非同期でツリーが未構築なことがあるため、leaf が現れるまで待って
  // (最大 ~30秒)から一度だけ反映する。
  let attempts = 0;
  initialReflectTimer = setInterval(() => {
    attempts += 1;
    if (hasAnyLeaf(controller.items) || attempts >= INITIAL_REFLECT_MAX_ATTEMPTS) {
      if (initialReflectTimer) {
        clearInterval(initialReflectTimer);
        initialReflectTimer = undefined;
      }
      applyTick();
    }
  }, INITIAL_REFLECT_POLL_MS);

  return {
    dispose(): void {
      fsWatcher?.close();
      if (dirRetryTimer) {
        clearInterval(dirRetryTimer);
      }
      if (debounceTimer) {
        clearTimeout(debounceTimer);
      }
      if (initialReflectTimer) {
        clearInterval(initialReflectTimer);
      }
    },
  };
}
