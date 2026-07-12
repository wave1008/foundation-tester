// extension.ts
// 拡張のエントリポイント。activate() で各コンポーネントを組み立てて登録する。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { FtesterCli } from "./cli";
import {
  type FtesterConfig,
  listProjectCandidates,
  listRunProfileNames,
  readConfig,
  resolveProjectName,
  resolveWorkspaceRoot,
} from "./config";
import { registerDebugAdapter } from "./debugConfig";
import { registerHealReviewPanel } from "./healReviewPanel";
import { registerMonitorPanel } from "./monitorPanel";
import { sweepOrphans } from "./orphanSweep";
import { registerProfileDiagnostics } from "./profileDiagnostics";
import { RunEventBus } from "./runEventBus";
import { registerRunHandler } from "./runHandler";
import { registerStepsView } from "./stepsView";
import { FtesterTestTree } from "./testTree";
import { ScenarioFileWatcher } from "./watcher";

export function activate(context: vscode.ExtensionContext): void {
  const outputChannel = vscode.window.createOutputChannel("ftester");
  context.subscriptions.push(outputChannel);

  // 孤児化した常駐プロセス(reload window 等で拡張ホストが即死し PPID=1 になったもの)の掃除。
  // best-effort・fire-and-forget(失敗しても activate を止めない。orphanSweep.ts 参照)。
  void sweepOrphans((message) => outputChannel.appendLine(message));

  const workspaceRoot = resolveWorkspaceRoot();
  if (!workspaceRoot) {
    // 無言で終わると「ビューに provider が無い」という分かりにくい表示になるため理由を明示する。
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
    // ftester のテストプロジェクトを持たないリポジトリでは登録しない。
    outputChannel.appendLine(
      `[ftester] ${workspaceRoot} に Projects/ が見つからないため初期化しません。`,
    );
    return;
  }
  outputChannel.appendLine(`[ftester] 初期化しました: ${workspaceRoot}`);

  const cli = new FtesterCli(outputChannel);
  const getConfig = (): FtesterConfig => readConfig(workspaceRoot);

  // runHandler と monitorPanel へ配信する共有インスタンス(runEventBus.ts 参照)。
  const runEventBus = new RunEventBus();

  const testTree = registerTestTree(context, cli, workspaceRoot, getConfig, outputChannel);
  const watcher = registerWatcher(context, workspaceRoot, testTree);
  registerCommands(context, workspaceRoot, testTree, getConfig, outputChannel);
  registerRunHandler(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel, runEventBus);
  registerDebugAdapter(context, workspaceRoot, getConfig, outputChannel);
  registerStepsView(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel);
  registerMonitorPanel(context, workspaceRoot, getConfig, outputChannel, runEventBus, cli, testTree);
  registerHealReviewPanel(context, workspaceRoot, getConfig, outputChannel, runEventBus, cli);
  registerProfileDiagnostics(context, cli, workspaceRoot, getConfig, outputChannel);

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
  getConfig: () => FtesterConfig,
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
    vscode.commands.registerCommand("ftester.selectProfile", async () => {
      const config = getConfig();
      const resolution = resolveProjectName(workspaceRoot, config);
      if (resolution.kind !== "resolved") {
        void vscode.window.showWarningMessage(
          "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        );
        return;
      }
      const names = listRunProfileNames(workspaceRoot, resolution.project);
      const NONE_LABEL = "(プロファイルなし)";
      const items: vscode.QuickPickItem[] = [
        {
          label: config.profile === "" ? `$(check) ${NONE_LABEL}` : NONE_LABEL,
          description: config.profile === "" ? "現在の設定" : undefined,
        },
        ...names.map((name) => ({
          label: config.profile === name ? `$(check) ${name}` : name,
          description: config.profile === name ? "現在の設定" : undefined,
        })),
      ];
      const picked = await vscode.window.showQuickPick(items, {
        placeHolder:
          `使用する実行プロファイルを選択してください` +
          `(Projects/${resolution.project}/profiles/runs/ の一覧)`,
      });
      if (!picked) {
        return;
      }
      const rawLabel = picked.label.startsWith("$(check) ") ? picked.label.slice("$(check) ".length) : picked.label;
      const value = rawLabel === NONE_LABEL ? "" : rawLabel;
      await vscode.workspace
        .getConfiguration("ftester")
        .update("profile", value, vscode.ConfigurationTarget.Workspace);
      const displayValue = value === "" ? NONE_LABEL : value;
      outputChannel.appendLine(`[ftester] 実行プロファイルを「${displayValue}」に設定しました。`);
      void vscode.window.showInformationMessage(`ftester: 実行プロファイルを「${displayValue}」に設定しました。`);
    }),
  );
}
