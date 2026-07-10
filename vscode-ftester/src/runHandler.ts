// runHandler.ts
// Test Explorer の Run プロファイル(「実行」「実行 (dry-run)」「デバッグ」)を登録する。
//
// 「実行」系は1回の `ftester api run` に対象シナリオ ID を全て --scenario で渡し
// (CLI 側が逐次実行する)、stdout の NDJSON イベントを runReducer.reduceRunEvent で
// アクション列に変換して vscode.TestRun(run.started/appendOutput/passed/failed/errored/end)へ
// 適用する。runReducer.ts は vscode に依存しない純粋なロジックなので、ここでは
// アクション → vscode API 呼び出しの変換だけを担当する。
//
// 「デバッグ」プロファイルは対象を1件(leaf)だけ受け付け、vscode.debug.startDebugging で
// debugConfig.ts/debugAdapter.ts のデバッグアダプタに実行を委譲する。結果は
// カスタムイベント `ftester.scenarioFinished`(debugAdapter.ts が scenarioFinished を
// 中継したもの)を購読して run.passed/failed に反映し、セッション終了で run.end() する。

import * as path from "node:path";
import * as vscode from "vscode";
import { type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
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

export function registerRunHandler(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  testTree: FtesterTestTree,
  watcher: ScenarioFileWatcher,
  outputChannel: vscode.OutputChannel,
  eventBus: RunEventBus,
): void {
  const controller = testTree.controller;

  const makeHandler = (dryRun: boolean) =>
    (request: vscode.TestRunRequest, token: vscode.CancellationToken): Thenable<void> =>
      executeRun(controller, cli, workspaceRoot, getConfig, watcher, outputChannel, eventBus, request, token, dryRun);

  context.subscriptions.push(
    controller.createRunProfile("実行", vscode.TestRunProfileKind.Run, makeHandler(false), true),
    controller.createRunProfile(
      "実行 (dry-run)",
      vscode.TestRunProfileKind.Run,
      makeHandler(true),
      false,
    ),
    controller.createRunProfile(
      "デバッグ",
      vscode.TestRunProfileKind.Debug,
      (request, token) => executeDebugRun(controller, workspaceRoot, getConfig, watcher, request, token),
      true,
    ),
  );
}

/**
 * request.include/exclude を、実行対象のシナリオ leaf(TestItem。id = シナリオID生文字列)の
 * Map<id, TestItem> に解決する。
 *
 * - include 未指定: ツリー全体の leaf(@Deleted は除外)。
 * - folder/class ノードが include されている場合: 配下の leaf に展開する(@Deleted は除外。
 *   CLI 側の「クラス名指定では削除済みを実行しない」規則と一致させるため)。
 * - leaf 自体が明示的に include されている場合: @Deleted でもそのまま対象にする
 *   (CLI 側の「完全一致指定のときだけ削除済みを実行する」規則と一致させるため)。
 * - exclude は上記の結果から leaf 単位で取り除く(folder/class が exclude された場合は
 *   配下の leaf を丸ごと除外する)。
 */
function resolveTargets(
  controller: vscode.TestController,
  request: vscode.TestRunRequest,
): Map<string, vscode.TestItem> {
  const result = new Map<string, vscode.TestItem>();

  const addSubtree = (item: vscode.TestItem, explicit: boolean): void => {
    if (item.children.size === 0) {
      // leaf(シナリオ)。explicit(この item 自体が include に指定された)のときだけ
      // @Deleted でも対象に含める
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
): Promise<void> {
  const config = getConfig();
  const targets = resolveTargets(controller, request);
  const run = controller.createTestRun(request);

  if (targets.size === 0) {
    run.end();
    return;
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
  // profile が非空のときはそちらだけを渡す(空なら従来通り platform/port/serial を渡す)。
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

  const finished = new Set<string>();
  let sawEnd = false;
  let reducerState = createRunReducerState();
  // workersReady(並列実行時のみ)で埋まる worker id → デバイス名。output のプレフィックスに使う。
  const workerNames = new Map<string, string>();

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
      onLog: (line, stream) => outputChannel.appendLine(`[${stream}] ${line}`),
    });

    if (!sawEnd && result.exitCode !== 0) {
      // runFinished を受信しないまま(異常終了 / デバイス切断など)プロセスが終了した。
      // まだ完了していない対象は errored にして、実行結果が不明のまま放置しないようにする
      const message = result.cancelled
        ? "実行がキャンセルされました。"
        : `ftester プロセスが異常終了しました(exit code: ${String(result.exitCode)})。出力パネル「ftester」を確認してください。`;
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
    run.end();
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
  // --profile と --platform/--port/--serial は ftester api run 側で同時指定不可なので、
  // profile が非空のときはそちらだけを渡す(空なら従来通り platform/port/serial を渡す)。
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
    run.end();
  }
}
