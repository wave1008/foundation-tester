// runHandler.ts
// Test Explorer の Run プロファイル(「実行」「実行 (dry-run)」「デバッグ」)を登録する。
//
// 「実行」系は1回の `ftester api run` に対象シナリオ ID を全て --scenario で渡す
// (CLI 側が逐次実行する)。runReducer.ts(vscode 非依存の純粋ロジック)が NDJSON イベントを
// アクション列に変換し、ここではそれを vscode.TestRun API 呼び出しへ適用するだけを担当する。
//
// 「デバッグ」プロファイルは vscode.debug.startDebugging で debugConfig.ts/debugAdapter.ts に
// 委譲する(詳細は executeDebugRun 参照)。結果はカスタムイベント `ftester.scenarioFinished`
// (debugAdapter.ts が中継)を購読して run.passed/failed に反映する。

import * as path from "node:path";
import * as vscode from "vscode";
import { type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import { resolveEntryAtCursor, truncateForStatusBar, type TreeItemEntry } from "./copyTestName";
import { lastResultsDir, lookupKey, readFailedScenarioIds } from "./lastResults";
import { findLatestReport, listRecentReports, reportsDir } from "./scenarioReports";
import type { ScenarioFinishedEventBody } from "./debugAdapter";
import { isRunEvent } from "./model";
import { type RunEventBus } from "./runEventBus";
import {
  createRunReducerState,
  reduceRunEvent,
  type RunAction,
  type RunLocation,
} from "./runReducer";
import { DELETED_TAG, type FtesterTestTree } from "./testTree";
import type { ScenarioFileWatcher } from "./watcher";

// lastResultsSync.ts の isGuiRunActive が参照する(GUI 実行中はツリーへの反映を譲る)。
let activeRunCount = 0;
export function isRunActive(): boolean {
  return activeRunCount > 0;
}

// コントローラ行(ルートの「ftester」)の右クリックは TestItem でない内部オブジェクト
// (id が undefined)が渡る。TestItem として妥当なものだけ採用し、それ以外は全体扱い
export function isTestItem(x: unknown): x is vscode.TestItem {
  return typeof x === "object" && x !== null
    && typeof (x as vscode.TestItem).id === "string"
    && typeof (x as vscode.TestItem).children === "object";
}

export function registerRunHandler(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  testTree: FtesterTestTree,
  watcher: ScenarioFileWatcher,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  // GUI 実行(実行/デバッグ)が終わるたびに呼ぶ(reportCodeLens.ts の refresh 用。last-results が
  // 変化し得るタイミング)。
  onRunFinished?: () => void,
): void {
  const controller = testTree.controller;

  const makeHandler = (dryRun: boolean, failedOnly = false) =>
    (request: vscode.TestRunRequest, token: vscode.CancellationToken): Thenable<void> =>
      executeRun(
        controller,
        cli,
        workspaceRoot,
        getConfig,
        watcher,
        outputChannel,
        eventBus,
        request,
        token,
        dryRun,
        failedOnly,
        onRunFinished,
      );

  // ftester.rerunFailedTests(testing/item/context)と「失敗のみ実行」プロファイルは同じ handler を
  // 共有する(パイプライン重複を避けるため)。
  const failedOnlyHandler = makeHandler(false, true);
  const failedOnlyProfile = controller.createRunProfile(
    "失敗のみ実行",
    vscode.TestRunProfileKind.Run,
    failedOnlyHandler,
    false,
  );

  context.subscriptions.push(
    controller.createRunProfile("実行", vscode.TestRunProfileKind.Run, makeHandler(false), true),
    controller.createRunProfile(
      "実行 (dry-run)",
      vscode.TestRunProfileKind.Run,
      makeHandler(true),
      false,
    ),
    failedOnlyProfile,
    controller.createRunProfile(
      "デバッグ",
      vscode.TestRunProfileKind.Debug,
      (request, token) =>
        executeDebugRun(controller, workspaceRoot, getConfig, watcher, request, token, onRunFinished),
      true,
    ),
    vscode.commands.registerCommand(
      "ftester.rerunFailedTests",
      (item?: unknown, items?: unknown) => {
        const multi = Array.isArray(items) ? items.filter(isTestItem) : [];
        const include = multi.length > 0 ? multi : isTestItem(item) ? [item] : undefined;
        outputChannel.appendLine(
          `[rerunFailed] include=${include ? include.map((i) => i.id).join(",") : "全体"}`);
        const request = new vscode.TestRunRequest(include, undefined, failedOnlyProfile);
        const tokenSource = new vscode.CancellationTokenSource();
        void Promise.resolve(failedOnlyHandler(request, tokenSource.token)).finally(() =>
          tokenSource.dispose(),
        );
      },
    ),
    vscode.commands.registerCommand(
      "ftester.copyTestName",
      (item?: unknown, items?: unknown) => {
        const multi = Array.isArray(items) ? items.filter(isTestItem) : [];
        const include = multi.length > 0 ? multi : isTestItem(item) ? [item] : undefined;

        if (include && include.length > 0) {
          void copyAndNotify(include.map((i) => i.label).join("\n"));
          return;
        }

        const notFound = () =>
          vscode.window.setStatusBarMessage(
            "コピー対象を特定できませんでした(Test Explorer で右クリック → 名前をコピー)", 3000);

        const activeEditor = vscode.window.activeTextEditor;
        if (!activeEditor) {
          notFound();
          return;
        }
        const entries: TreeItemEntry[] = [];
        const collect = (treeItem: vscode.TestItem, depth: number): void => {
          if (treeItem.uri && treeItem.range) {
            entries.push({
              id: treeItem.id,
              label: treeItem.label,
              uriKey: treeItem.uri.toString(),
              startLine: treeItem.range.start.line,
              depth,
            });
          }
          treeItem.children.forEach((child) => collect(child, depth + 1));
        };
        controller.items.forEach((treeItem) => collect(treeItem, 0));

        const cursor = {
          uriKey: activeEditor.document.uri.toString(),
          line: activeEditor.selection.active.line,
        };
        const resolved = resolveEntryAtCursor(entries, cursor);
        if (!resolved) {
          notFound();
          return;
        }
        void copyAndNotify(resolved.label);
      },
    ),
    vscode.commands.registerCommand(
      "ftester.openScenarioReport",
      // item が string: lastResultsSync.ts の markdown リンク(command:ftester.openScenarioReport)
      // からのシナリオID直渡し。leaf TestItem: children.size===0(resolveTargets と同じ leaf 規則)。
      // それ以外(class/folder の TestItem、または未指定=ルート右クリック)は配下 leaf を全展開する。
      async (item?: unknown, ..._args: unknown[]) => {
        if (typeof item === "string") {
          await openLatestReportForScenario(workspaceRoot, getConfig, item);
          return;
        }
        if (isTestItem(item) && item.children.size === 0) {
          await openLatestReportForScenario(workspaceRoot, getConfig, item.id);
          return;
        }
        const leafIds: string[] = [];
        collectLeafScenarioIds(isTestItem(item) ? item.children : controller.items, leafIds);
        await openReportForScenarios(workspaceRoot, getConfig, leafIds);
      },
    ),
  );
}

async function copyAndNotify(text: string): Promise<void> {
  await vscode.env.clipboard.writeText(text);
  vscode.window.setStatusBarMessage(`コピーしました: ${truncateForStatusBar(text)}`, 3000);
}

/** 失敗メッセージ末尾に添える「レポートを開く」リンク(lastResultsSync.ts の CLI 反映側と同じ
 * コマンド URI。レポートはクリック時に最新を解決するため、イベント時点でのパス解決は不要)。 */
export function buildReportLinkMessage(scenarioId: string): vscode.TestMessage {
  const args = encodeURIComponent(JSON.stringify([scenarioId]));
  const markdown = new vscode.MarkdownString(
    `[レポートを開く](command:ftester.openScenarioReport?${args})`,
  );
  markdown.isTrusted = { enabledCommands: ["ftester.openScenarioReport"] };
  return new vscode.TestMessage(markdown);
}

async function openReport(reportPath: string): Promise<void> {
  try {
    // markdown プレビューはレポート埋め込みの screenshot 画像リンクを描画できる。ToSide で
    // CodeLens/失敗メッセージのあるエディタを隠さず横に開く。
    await vscode.commands.executeCommand("markdown.showPreviewToSide", vscode.Uri.file(reportPath));
  } catch {
    await vscode.window.showTextDocument(vscode.Uri.file(reportPath));
  }
}

function collectLeafScenarioIds(items: vscode.TestItemCollection, out: string[]): void {
  items.forEach((item) => {
    if (item.children.size === 0) {
      out.push(item.id);
    } else {
      collectLeafScenarioIds(item.children, out);
    }
  });
}

async function openLatestReportForScenario(
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  scenarioId: string,
): Promise<void> {
  const resolution = resolveProjectName(workspaceRoot, getConfig());
  if (resolution.kind !== "resolved") {
    void vscode.window.showInformationMessage("対象のテストプロジェクトを解決できませんでした。");
    return;
  }
  const found = findLatestReport(reportsDir(workspaceRoot, resolution.project), scenarioId);
  if (!found) {
    void vscode.window.showInformationMessage(`レポートが見つかりません: ${scenarioId}`);
    return;
  }
  await openReport(found);
}

async function openReportForScenarios(
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  scenarioIds: string[],
): Promise<void> {
  const resolution = resolveProjectName(workspaceRoot, getConfig());
  if (resolution.kind !== "resolved") {
    void vscode.window.showInformationMessage("対象のテストプロジェクトを解決できませんでした。");
    return;
  }
  const reports = listRecentReports(reportsDir(workspaceRoot, resolution.project), new Set(scenarioIds));
  if (reports.length === 0) {
    void vscode.window.showInformationMessage("レポートが見つかりません。");
    return;
  }
  if (reports.length === 1) {
    await openReport(reports[0]!.path);
    return;
  }
  const picked = await vscode.window.showQuickPick(
    reports.map((r) => ({ label: r.scenarioId, description: r.fileName, reportPath: r.path })),
    { placeHolder: "開くレポートを選択" },
  );
  if (picked) {
    await openReport(picked.reportPath);
  }
}

/**
 * request.include/exclude を対象シナリオ leaf(TestItem、id=シナリオID)の Map<id, TestItem> に解決する。
 * include 未指定なら全 leaf(@Deleted 除外)。folder/class の include は配下 leaf に展開(@Deleted 除外、
 * CLI の「クラス名指定では削除済みを実行しない」規則と一致)。leaf 自体が明示 include されたときは
 * @Deleted でも対象にする(CLI の「完全一致指定のときだけ削除済みを実行する」規則と一致)。
 * exclude は leaf 単位で除去(folder/class の exclude は配下 leaf を丸ごと除外)。
 */
function resolveTargets(
  controller: vscode.TestController,
  request: vscode.TestRunRequest,
): Map<string, vscode.TestItem> {
  const result = new Map<string, vscode.TestItem>();

  const addSubtree = (item: vscode.TestItem, explicit: boolean): void => {
    if (item.children.size === 0) {
      // explicit(この item 自体が include 指定)のときのみ @Deleted でも対象にする。
      if (explicit || !isDeleted(item)) {
        result.set(item.id, item);
      }
      return;
    }
    item.children.forEach((child) => addSubtree(child, false));
  };

  if (request.include && request.include.length > 0) {
    for (const item of request.include) {
      addSubtree(item, true);
    }
  } else {
    controller.items.forEach((item) => addSubtree(item, false));
  }

  const removeSubtree = (item: vscode.TestItem): void => {
    if (item.children.size === 0) {
      result.delete(item.id);
      return;
    }
    item.children.forEach((child) => removeSubtree(child));
  };
  for (const item of request.exclude ?? []) {
    removeSubtree(item);
  }

  return result;
}

function isDeleted(item: vscode.TestItem): boolean {
  return item.tags.some((tag) => tag.id === DELETED_TAG.id);
}

async function executeRun(
  controller: vscode.TestController,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  watcher: ScenarioFileWatcher,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
  request: vscode.TestRunRequest,
  token: vscode.CancellationToken,
  dryRun: boolean,
  failedOnly: boolean,
  onRunFinished?: () => void,
): Promise<void> {
  const config = getConfig();
  let targets = resolveTargets(controller, request);

  if (failedOnly) {
    const resolution = resolveProjectName(workspaceRoot, config);
    const failedIds =
      resolution.kind === "resolved"
        ? readFailedScenarioIds(lastResultsDir(workspaceRoot, resolution.project))
        : new Set<string>();
    outputChannel.appendLine(
      `[rerunFailed] project=${resolution.kind === "resolved" ? resolution.project : resolution.kind}`
      + ` 展開=${targets.size}件 失敗記録=${failedIds.size}件`
      + ` 対象=${[...targets.keys()].filter((id) => failedIds.has(lookupKey(id))).length}件`);
    targets = new Map([...targets].filter(([id]) => failedIds.has(lookupKey(id))));
  }

  const run = controller.createTestRun(request);
  const runStartedAt = Date.now();

  if (targets.size === 0) {
    if (failedOnly) {
      run.appendOutput("前回失敗したシナリオはありません(全て成功済みか未実行)\r\n");
      // 実行が一瞬で終わり run 出力は見落としやすいため、可視の通知も出す
      void vscode.window.showInformationMessage(
        "ftester: 前回失敗したシナリオはありません(全て成功済みか未実行)");
    }
    run.end();
    return;
  }

  // キュー投入時点で全対象を enqueued にし、前回の合否アイコンをリセットして待機表示にする
  // (started は各シナリオ開始時に個別に来るため、それまで前回結果が残るのを防ぐ)。
  for (const item of targets.values()) {
    run.enqueued(item);
  }

  const resolution = resolveProjectName(workspaceRoot, config);
  if (resolution.kind !== "resolved") {
    run.appendOutput(
      "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。\r\n",
    );
    for (const item of targets.values()) {
      run.errored(item, new vscode.TestMessage("対象のテストプロジェクトを解決できませんでした。"));
    }
    run.end();
    return;
  }

  const args = ["api", "run", "--project", resolution.project];
  for (const id of targets.keys()) {
    args.push("--scenario", id);
  }
  // --profile と --platform/--port/--serial は ftester api run 側で同時指定不可なので、
  // profile が非空のときはそちらだけを渡す(空なら platform/port/serial を渡す)。
  const profile = config.profile.trim();
  if (profile.length > 0) {
    args.push("--profile", profile);
  } else {
    args.push("--platform", config.platform);
    if (config.port > 0) {
      args.push("--port", String(config.port));
    }
    if (config.serial.trim().length > 0) {
      args.push("--serial", config.serial);
    }
  }
  if (!config.buildBeforeRun) {
    args.push("--skip-build");
  }
  // --heal は dry-run には付与しない(dry-run はワーカー構築自体を省略するデバイス不要の
  // 検証実行であり、自己修復の対象になる実機動作が発生しないため)。
  if (config.heal && !dryRun) {
    args.push("--heal");
  }
  if (dryRun) {
    args.push("--dry-run");
  }

  watcher.setSuspended(true);
  activeRunCount += 1;

  const finished = new Set<string>();
  let sawEnd = false;
  let reducerState = createRunReducerState();
  // workersReady(並列実行時のみ)で埋まる worker id → デバイス名。output のプレフィックスに使う。
  const workerNames = new Map<string, string>();
  const stderrTail: string[] = [];

  const toLocation = (location: RunLocation | undefined): vscode.Location | undefined => {
    if (!location) {
      return undefined;
    }
    const absolute = path.isAbsolute(location.file)
      ? location.file
      : path.join(workspaceRoot, location.file);
    const line = Math.max(0, location.line - 1); // 1起点 → 0起点
    return new vscode.Location(vscode.Uri.file(absolute), new vscode.Position(line, 0));
  };

  const applyAction = (action: RunAction): void => {
    switch (action.type) {
      case "started": {
        const item = targets.get(action.scenario);
        if (item) {
          run.started(item);
        }
        break;
      }
      case "output": {
        const item = action.scenario ? targets.get(action.scenario) : undefined;
        const prefix = action.worker ? `[${workerNames.get(action.worker) ?? action.worker}] ` : "";
        run.appendOutput(`${prefix}${action.text}\r\n`, toLocation(action.location), item);
        break;
      }
      case "passed": {
        finished.add(action.scenario);
        const item = targets.get(action.scenario);
        if (item) {
          run.passed(item, action.durationMs);
        }
        break;
      }
      case "failed": {
        finished.add(action.scenario);
        const item = targets.get(action.scenario);
        if (item) {
          const messages = action.messages.map((m) => {
            const message = new vscode.TestMessage(m.text);
            message.location = toLocation(m.location);
            return message;
          });
          // dry-run はレポートを出力しないためリンクを付けない
          if (!dryRun) {
            const link = buildReportLinkMessage(action.scenario);
            link.location = messages[0]?.location
              ?? (item.uri && item.range ? new vscode.Location(item.uri, item.range) : undefined);
            messages.push(link);
          }
          run.failed(item, messages, action.durationMs);
        }
        break;
      }
      case "end":
        sawEnd = true;
        break;
      case "workers":
        for (const worker of action.workers) {
          workerNames.set(worker.id, worker.name);
        }
        break;
    }
  };

  const cancelListener = token.onCancellationRequested(() => {
    cli.cancelCurrent();
  });

  const runId = eventBus.beginRun(dryRun);

  try {
    const result = await cli.invoke(config.binaryPath, workspaceRoot, {
      args,
      onNdjsonValue: (value) => {
        if (isRunEvent(value)) {
          eventBus.publish(runId, value);
        }
        const { state, actions } = reduceRunEvent(reducerState, value, Date.now());
        reducerState = state;
        for (const action of actions) {
          applyAction(action);
        }
      },
      onLog: (line, stream) => {
        outputChannel.appendLine(`[${stream}] ${line}`);
        if (stream === "stderr") {
          stderrTail.push(line);
          if (stderrTail.length > 8) {
            stderrTail.shift();
          }
        }
      },
    });

    if (!sawEnd && result.exitCode !== 0) {
      // runFinished を受信しないまま(異常終了 / デバイス切断など)プロセスが終了した。
      // まだ完了していない対象は errored にして、実行結果が不明のまま放置しないようにする
      const tail = stderrTail.length > 0 ? `\n--- stderr 末尾 ---\n${stderrTail.join("\n")}` : "";
      const message = result.cancelled
        ? "実行がキャンセルされました。"
        : `ftester プロセスが異常終了しました(exit code: ${String(result.exitCode)})。` +
          `出力パネル「ftester」を確認してください。${tail}`;
      markRemainingErrored(run, targets, finished, message);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    outputChannel.appendLine(`[ftester] ${message}`);
    void vscode.window.showWarningMessage(
      `ftester CLI の実行に失敗しました(${message})。出力パネル「ftester」を確認してください。`,
    );
    markRemainingErrored(run, targets, finished, message);
  } finally {
    eventBus.endRun(runId);
    cancelListener.dispose();
    watcher.setSuspended(false);
    activeRunCount -= 1;
    // キャンセル・異常終了でも経過は出す(TEST RESULTS の末尾行)
    const totalSeconds = ((Date.now() - runStartedAt) / 1000).toFixed(1);
    run.appendOutput(`\r\n⏱ トータル: ${totalSeconds}s\r\n`);
    run.end();
    onRunFinished?.();
  }
}

function markRemainingErrored(
  run: vscode.TestRun,
  targets: Map<string, vscode.TestItem>,
  finished: Set<string>,
  message: string,
): void {
  for (const [id, item] of targets) {
    if (!finished.has(id)) {
      run.errored(item, new vscode.TestMessage(message));
    }
  }
}

/**
 * デバッグ実行(vscode.debug.startDebugging 経由で debugConfig.ts/debugAdapter.ts に委譲)。
 * 1件の leaf のみ対応する(複数・folder/class を選択した場合は先頭の leaf のみ実行し警告する)。
 */
async function executeDebugRun(
  controller: vscode.TestController,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  watcher: ScenarioFileWatcher,
  request: vscode.TestRunRequest,
  token: vscode.CancellationToken,
  onRunFinished?: () => void,
): Promise<void> {
  const config = getConfig();
  const targets = resolveTargets(controller, request);
  const run = controller.createTestRun(request);

  if (targets.size === 0) {
    run.end();
    return;
  }
  if (targets.size > 1) {
    void vscode.window.showWarningMessage(
      "ftester: デバッグ実行は1件のシナリオのみ対応しています。先頭の1件のみ実行します。",
    );
  }
  const [id, item] = [...targets.entries()][0]!;

  // キュー投入時点で前回の合否アイコンをリセットして待機表示にする(started は下で来る)。
  run.enqueued(item);

  const resolution = resolveProjectName(workspaceRoot, config);
  if (resolution.kind !== "resolved") {
    run.appendOutput(
      "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。\r\n",
    );
    run.errored(item, new vscode.TestMessage("対象のテストプロジェクトを解決できませんでした。"));
    run.end();
    return;
  }

  const debugConfig: vscode.DebugConfiguration = {
    type: "ftester",
    request: "launch",
    name: id,
    project: resolution.project,
    scenario: id,
    skipBuild: !config.buildBeforeRun,
    heal: config.heal,
  };
  // --profile と --platform/--port/--serial の組合せ規則は executeRun 参照。
  const profile = config.profile.trim();
  if (profile.length > 0) {
    debugConfig.profile = profile;
  } else {
    debugConfig.platform = config.platform;
    if (config.port > 0) {
      debugConfig.port = config.port;
    }
    if (config.serial.trim().length > 0) {
      debugConfig.serial = config.serial;
    }
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(
    item.uri ?? vscode.Uri.file(workspaceRoot),
  );

  const matchesThisRun = (candidate: vscode.DebugSession): boolean =>
    candidate.type === "ftester" && candidate.configuration.scenario === id;

  let session: vscode.DebugSession | undefined;
  let outcome: { passed: boolean; reportPath?: string } | undefined;

  const startListener = vscode.debug.onDidStartDebugSession((started) => {
    if (matchesThisRun(started)) {
      session = started;
    }
  });
  const customEventListener = vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => {
    if (!matchesThisRun(e.session) || e.event !== "ftester.scenarioFinished") {
      return;
    }
    const body = e.body as ScenarioFinishedEventBody | undefined;
    outcome = { passed: body?.passed === true, reportPath: body?.reportPath };
  });
  const cancelListener = token.onCancellationRequested(() => {
    if (session) {
      void vscode.debug.stopDebugging(session);
    }
  });

  watcher.setSuspended(true);
  activeRunCount += 1;
  run.started(item);

  try {
    const started = await vscode.debug.startDebugging(workspaceFolder, debugConfig);
    if (!started) {
      run.errored(item, new vscode.TestMessage("デバッグセッションを開始できませんでした。"));
      return;
    }

    await new Promise<void>((resolve) => {
      const terminateListener = vscode.debug.onDidTerminateDebugSession((terminated) => {
        if (!matchesThisRun(terminated)) {
          return;
        }
        terminateListener.dispose();
        resolve();
      });
    });

    if (outcome) {
      if (outcome.passed) {
        run.passed(item);
      } else {
        const reportSuffix = outcome.reportPath ? ` — レポート: ${outcome.reportPath}` : "";
        run.failed(item, new vscode.TestMessage(`シナリオが失敗しました${reportSuffix}`));
      }
    } else {
      run.errored(
        item,
        new vscode.TestMessage(
          "実行結果を受信できませんでした(セッションが異常終了した可能性があります)。" +
            "出力パネル「ftester」を確認してください。",
        ),
      );
    }
  } finally {
    startListener.dispose();
    customEventListener.dispose();
    cancelListener.dispose();
    watcher.setSuspended(false);
    activeRunCount -= 1;
    run.end();
    onRunFinished?.();
  }
}
