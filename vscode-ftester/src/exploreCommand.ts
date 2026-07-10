// exploreCommand.ts
// コマンド `ftester.explore`(「ftester: FM探索でシナリオを生成」)。macOS GUI 版(`ftester-gui`)の
// 「FM探索」タブに相当する機能で、FM エージェントによるアプリ探索 → Swift シナリオ生成
// (`ftester api explore`)を実行する。
//
// - デバイス選択は `ftester api list-devices` の結果を liveModel.ts の既存ヘルパー
//   (devicesToOptions/buildDeviceArgs)で処理する(livePanel.ts と同じ変換ロジックを再利用)。
// - `ftester api explore` は内部で `swift build`(生成コードのビルド検証)を行うため、
//   livePanel.ts の runOneShot(専用 spawn。FtesterCli のキューを使わない)ではなく、
//   cli.ts の FtesterCli(直列実行キュー)経由で実行する。これにより SPM のビルドロックが
//   `ftester api run` 等の他の CLI 呼び出しと衝突しない(キューが同時に1プロセックスしか
//   走らせない仕様に自然に乗る)。ストリーミング(NDJSON 1行ごとのコールバック)とキャンセル
//   (SIGTERM → 2秒後 SIGKILL)はいずれも cli.ts の invoke()/cancelCurrent() が既に提供している
//   ため、cli.ts 自体への変更は不要だった。
// - 実行中は `vscode.window.withProgress`(Notification、cancellable)で進捗を表示し、
//   exploreStep イベント毎に「[n/N] description」へ更新する。全イベント + stderr は出力チャネル
//   「ftester」にも流す(exploreModel.formatExploreLogLine で整形)。
// - bundle ID は前回入力値を `context.workspaceState` に記憶し、次回起動時にプリフィルする。

import * as vscode from "vscode";
import { type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import {
  buildFinishedNotification,
  DEFAULT_MAX_STEPS,
  buildDeviceQuickPickItems,
  formatExploreLogLine,
  formatStepProgressMessage,
  isExploreEvent,
  parseMaxSteps,
  validateBundleIdInput,
  validateGoalInput,
  validateMaxStepsInput,
  type ExploreErrorEvent,
  type ExploreFinishedEvent,
} from "./exploreModel";
import { buildDeviceArgs, devicesToOptions, parseListDevicesResult, type LiveDeviceRef } from "./liveModel";
import type { FtesterTestTree } from "./testTree";

const WORKSPACE_STATE_BUNDLE_ID_KEY = "ftester.explore.lastBundleId";
const OPEN_FILE_LABEL = "ファイルを開く";

export function registerExploreCommand(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  testTree: FtesterTestTree,
  outputChannel: vscode.OutputChannel,
): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("ftester.explore", () =>
      runExplore(context, cli, workspaceRoot, getConfig, testTree, outputChannel),
    ),
  );
}

async function runExplore(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  testTree: FtesterTestTree,
  outputChannel: vscode.OutputChannel,
): Promise<void> {
  const config = getConfig();
  const resolution = resolveProjectName(workspaceRoot, config);
  if (resolution.kind !== "resolved") {
    void vscode.window.showWarningMessage(
      "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    );
    return;
  }
  const project = resolution.project;

  const device = await pickDevice(cli, workspaceRoot, config, project, outputChannel);
  if (!device) {
    return; // ユーザーがキャンセル、またはデバイス一覧取得に失敗(エラーは pickDevice 内で通知済み)
  }

  const bundleId = await promptBundleId(context);
  if (bundleId === undefined) {
    return;
  }
  void context.workspaceState.update(WORKSPACE_STATE_BUNDLE_ID_KEY, bundleId);

  const goal = await promptGoal();
  if (goal === undefined) {
    return;
  }

  const maxSteps = await promptMaxSteps();
  if (maxSteps === undefined) {
    return;
  }

  const args = [
    "api",
    "explore",
    "--project",
    project,
    "--bundle",
    bundleId,
    "--goal",
    goal,
    "--max-steps",
    String(maxSteps),
    ...buildDeviceArgs(device),
  ];

  await executeExplore(cli, workspaceRoot, config, args, testTree, outputChannel);
}

/** `api list-devices` を FtesterCli のキュー経由で実行し、QuickPick でデバイスを選ばせる。 */
async function pickDevice(
  cli: FtesterCli,
  workspaceRoot: string,
  config: FtesterConfig,
  project: string,
  outputChannel: vscode.OutputChannel,
): Promise<LiveDeviceRef | undefined> {
  try {
    const result = await cli.invoke(config.binaryPath, workspaceRoot, {
      args: ["api", "list-devices", "--project", project],
      onLog: (line, stream) => outputChannel.appendLine(`[explore list-devices ${stream}] ${line}`),
    });
    const parsed = parseListDevicesResult(result.json);
    if (!parsed) {
      void vscode.window.showErrorMessage(
        `ftester: デバイス一覧の取得に失敗しました(exit code: ${String(result.exitCode)})。` +
          `出力パネル「ftester」を確認してください。`,
      );
      return undefined;
    }
    if (parsed.devices.length === 0) {
      void vscode.window.showWarningMessage("ftester: 利用可能なデバイスがありません。");
      return undefined;
    }

    const items = buildDeviceQuickPickItems(devicesToOptions(parsed.devices));
    const picked = await vscode.window.showQuickPick(items, {
      title: "ftester: FM探索",
      placeHolder: "探索対象のデバイスを選択してください",
    });
    if (!picked) {
      return undefined;
    }
    return { platform: picked.device.platform, port: picked.device.port, serial: picked.device.serial };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    void vscode.window.showErrorMessage(`ftester: デバイス一覧の取得に失敗しました: ${message}`);
    return undefined;
  }
}

async function promptBundleId(context: vscode.ExtensionContext): Promise<string | undefined> {
  const previous = context.workspaceState.get<string>(WORKSPACE_STATE_BUNDLE_ID_KEY, "");
  const input = await vscode.window.showInputBox({
    title: "ftester: FM探索(1/3)",
    prompt: "対象アプリの bundle ID / パッケージ名",
    value: previous,
    validateInput: validateBundleIdInput,
  });
  return input === undefined ? undefined : input.trim();
}

async function promptGoal(): Promise<string | undefined> {
  const input = await vscode.window.showInputBox({
    title: "ftester: FM探索(2/3)",
    prompt: "テストの目標(自然言語)",
    placeHolder: "例: ログインしてホーム画面が表示されることを確認する",
    validateInput: validateGoalInput,
  });
  return input === undefined ? undefined : input.trim();
}

async function promptMaxSteps(): Promise<number | undefined> {
  const input = await vscode.window.showInputBox({
    title: "ftester: FM探索(3/3)",
    prompt: "最大ステップ数(1〜50)",
    value: String(DEFAULT_MAX_STEPS),
    validateInput: validateMaxStepsInput,
  });
  return input === undefined ? undefined : parseMaxSteps(input);
}

/** `api explore` を FtesterCli のキュー経由で実行し、進捗表示・キャンセル・完了通知を行う。 */
async function executeExplore(
  cli: FtesterCli,
  workspaceRoot: string,
  config: FtesterConfig,
  args: string[],
  testTree: FtesterTestTree,
  outputChannel: vscode.OutputChannel,
): Promise<void> {
  let finishedEvent: ExploreFinishedEvent | undefined;
  let errorEvent: ExploreErrorEvent | undefined;

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "ftester: FM探索",
      cancellable: true,
    },
    async (progress, token) => {
      progress.report({ message: "開始しています..." });
      const cancelListener = token.onCancellationRequested(() => {
        outputChannel.appendLine("[explore] キャンセル要求を受け取りました(SIGTERM を送信します)。");
        cli.cancelCurrent();
      });
      try {
        const result = await cli.invoke(config.binaryPath, workspaceRoot, {
          args,
          onNdjsonValue: (value) => {
            if (!isExploreEvent(value)) {
              return;
            }
            outputChannel.appendLine(formatExploreLogLine(value));
            if (value.kind === "exploreStep") {
              progress.report({ message: formatStepProgressMessage(value) });
            } else if (value.kind === "exploreFinished") {
              finishedEvent = value;
            } else if (value.kind === "error") {
              errorEvent = value;
            }
          },
          onLog: (line, stream) => outputChannel.appendLine(`[explore ${stream}] ${line}`),
        });
        if (!finishedEvent && !errorEvent && !result.cancelled) {
          errorEvent = {
            kind: "error",
            message: `ftester プロセスが異常終了しました(exit code: ${String(result.exitCode)})。出力パネル「ftester」を確認してください。`,
          };
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        outputChannel.appendLine(`[explore] ${message}`);
        errorEvent = { kind: "error", message };
      } finally {
        cancelListener.dispose();
      }
    },
  );

  if (finishedEvent) {
    void testTree.refresh();
    await notifyFinished(finishedEvent);
  } else if (errorEvent) {
    void vscode.window.showErrorMessage(`ftester: FM探索に失敗しました: ${errorEvent.message}`);
  }
  // どちらも無い場合(finishedEvent/errorEvent とも undefined)はユーザーによるキャンセル
  // (result.cancelled)。通知は不要(withProgress の Notification が消えるだけで十分)。
}

async function notifyFinished(event: ExploreFinishedEvent): Promise<void> {
  const notification = buildFinishedNotification(event);
  const hasFile = event.file !== null;

  let choice: string | undefined;
  if (notification.severity === "info") {
    choice = hasFile
      ? await vscode.window.showInformationMessage(notification.message, OPEN_FILE_LABEL)
      : await vscode.window.showInformationMessage(notification.message);
  } else {
    choice = hasFile
      ? await vscode.window.showWarningMessage(notification.message, OPEN_FILE_LABEL)
      : await vscode.window.showWarningMessage(notification.message);
  }

  if (choice === OPEN_FILE_LABEL && event.file) {
    const doc = await vscode.workspace.openTextDocument(event.file);
    await vscode.window.showTextDocument(doc);
  }
}
