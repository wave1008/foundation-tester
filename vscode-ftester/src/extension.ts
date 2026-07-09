// extension.ts
// 拡張のエントリポイント。activate() で各コンポーネントを組み立てて登録する。
//
// 後続フェーズ(runHandler/debugAdapter/stepsView)は、下の activate() 内のコメントの位置に
// 1〜2行で登録関数を追加できる構造にしてある。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { FtesterCli } from "./cli";
import { type FtesterConfig, listProjectCandidates, readConfig, resolveWorkspaceRoot } from "./config";
import { registerDebugAdapter } from "./debugConfig";
import { registerRunHandler } from "./runHandler";
import { registerStepsView } from "./stepsView";
import { FtesterTestTree } from "./testTree";
import { ScenarioFileWatcher } from "./watcher";

export function activate(context: vscode.ExtensionContext): void {
  const outputChannel = vscode.window.createOutputChannel("ftester");
  context.subscriptions.push(outputChannel);

  const workspaceRoot = resolveWorkspaceRoot();
  if (!workspaceRoot) {
    // Extension Development Host がフォルダー無しで開いた等。無言で終わると
    // 「ビューに provider が無い」という分かりにくい表示になるため理由を明示する。
    outputChannel.appendLine(
      "[ftester] フォルダーが開かれていないため初期化を中止しました。" +
        "foundation-tester リポジトリのフォルダーを開いてから再読み込みしてください。",
    );
    void vscode.window.showWarningMessage(
      "ftester: フォルダーが開かれていません。リポジトリのフォルダーを開いてください。",
    );
    return;
  }
  if (!hasProjectsDirectory(workspaceRoot)) {
    // Package.swift はあっても Projects/ が無い(ftester のテストプロジェクトを持たない)
    // リポジトリでは登録しない(ログにだけ理由を残す)。
    outputChannel.appendLine(
      `[ftester] ${workspaceRoot} に Projects/ が見つからないため初期化しません。`,
    );
    return;
  }
  outputChannel.appendLine(`[ftester] 初期化しました: ${workspaceRoot}`);

  const cli = new FtesterCli(outputChannel);
  const getConfig = (): FtesterConfig => readConfig(workspaceRoot);

  const testTree = registerTestTree(context, cli, workspaceRoot, getConfig, outputChannel);
  const watcher = registerWatcher(context, workspaceRoot, testTree);
  registerCommands(context, workspaceRoot, testTree, outputChannel);
  registerRunHandler(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel);
  registerDebugAdapter(context, workspaceRoot, getConfig, outputChannel);
  registerStepsView(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel);

  void testTree.refresh();
}

export function deactivate(): void {
  // 特別な後始末は不要(登録済みリソースは context.subscriptions 経由で dispose される)。
}

function hasProjectsDirectory(workspaceRoot: string): boolean {
  try {
    return fs.statSync(path.join(workspaceRoot, "Projects")).isDirectory();
  } catch {
    return false;
  }
}

function registerTestTree(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
): FtesterTestTree {
  const testTree = new FtesterTestTree(cli, () => workspaceRoot, getConfig, outputChannel);
  context.subscriptions.push(testTree);
  return testTree;
}

function registerWatcher(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  testTree: FtesterTestTree,
): ScenarioFileWatcher {
  const watcher = new ScenarioFileWatcher(workspaceRoot, () => void testTree.refresh());
  context.subscriptions.push(watcher);
  return watcher;
}

function registerCommands(
  context: vscode.ExtensionContext,
  workspaceRoot: string,
  testTree: FtesterTestTree,
  outputChannel: vscode.OutputChannel,
): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("ftester.refreshScenarios", () => {
      void testTree.refresh();
    }),
    vscode.commands.registerCommand("ftester.selectProject", async () => {
      const candidates = listProjectCandidates(workspaceRoot);
      if (candidates.length === 0) {
        void vscode.window.showWarningMessage(
          "ftester: Projects/ 配下にテストプロジェクトが見つかりません。",
        );
        return;
      }
      const picked = await vscode.window.showQuickPick(candidates, {
        placeHolder: "対象のテストプロジェクトを選択してください",
      });
      if (!picked) {
        return;
      }
      await vscode.workspace
        .getConfiguration("ftester")
        .update("project", picked, vscode.ConfigurationTarget.Workspace);
      outputChannel.appendLine(`[ftester] プロジェクトを「${picked}」に設定しました。`);
      void testTree.refresh();
    }),
  );
}
