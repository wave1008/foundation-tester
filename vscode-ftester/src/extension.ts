// extension.ts
// 拡張のエントリポイント。activate() で各コンポーネントを組み立てて登録する。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { type CliResult, FtesterCli } from "./cli";
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
import { registerLastResultsSync } from "./lastResultsSync";
import { registerMonitorPanel } from "./monitorPanel";
import { sweepOrphans } from "./orphanSweep";
import { registerProfileDiagnostics } from "./profileDiagnostics";
import { RunEventBus } from "./runEventBus";
import { isRunActive, registerRunHandler } from "./runHandler";
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
  registerCommands(context, cli, workspaceRoot, testTree, getConfig, outputChannel);
  registerRunHandler(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel, runEventBus);
  context.subscriptions.push(
    registerLastResultsSync({
      controller: testTree.controller,
      workspaceRoot,
      getConfig,
      isGuiRunActive: isRunActive,
      outputChannel,
    }),
  );
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

/** 指定ファイルを開いている全タブを閉じる。クラス削除(=ファイル削除)の前に呼び、削除後に
 * ダングリングエディタが残らないようにする(Tab API は engine ^1.90 で利用可能)。 */
async function closeEditorsForFile(fsPath: string): Promise<void> {
  const tabs = vscode.window.tabGroups.all
    .flatMap((group) => group.tabs)
    .filter((tab) => tab.input instanceof vscode.TabInputText && tab.input.uri.fsPath === fsPath);
  if (tabs.length > 0) {
    await vscode.window.tabGroups.close(tabs);
  }
}

/** メソッド削除で CLI がファイルを書き換えた後、開いているエディタをディスク内容へ揃える。
 * CLI の生ファイル書き込みは VSCode の自動リロードが効かない/遅いことがあるため確実に反映させる。
 * 未保存(dirty)のエディタは触らない(VSCode の競合解決に任せ、未保存編集を失わせない)。 */
async function syncOpenEditorToDisk(fsPath: string): Promise<void> {
  const doc = vscode.workspace.textDocuments.find(
    (d) => d.uri.fsPath === fsPath && !d.isClosed && !d.isDirty,
  );
  if (!doc) {
    return;
  }
  let diskContent: string;
  try {
    diskContent = fs.readFileSync(fsPath, "utf8");
  } catch {
    return;
  }
  if (doc.getText() === diskContent) {
    return; // 既に反映済み(VSCode 自動リロード等)
  }
  const edit = new vscode.WorkspaceEdit();
  edit.replace(
    doc.uri,
    new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length)),
    diskContent,
  );
  await vscode.workspace.applyEdit(edit);
  await doc.save(); // ディスクと一致させて未保存表示を残さない
}

function registerCommands(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  testTree: FtesterTestTree,
  getConfig: () => FtesterConfig,
  outputChannel: vscode.OutputChannel,
): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("ftester.refreshScenarios", () => {
      void testTree.refresh();
    }),
    // TEST EXPLORER の右クリック物理削除。対向: package.json testing/item/context(z_delete)、
    // ftester api delete-scenario。テストアイテム id は class:<folder>/<class> か <Class>.<Method>。
    vscode.commands.registerCommand("ftester.deleteScenario", async (item?: vscode.TestItem) => {
      if (!item || item.id.startsWith("folder:")) {
        return;
      }
      const file = item.uri?.fsPath;
      if (!file) {
        void vscode.window.showErrorMessage("ftester: 削除対象のファイルを特定できませんでした。");
        return;
      }
      const isClass = item.id.startsWith("class:");
      let className: string;
      let method: string | undefined;
      if (isClass) {
        className = item.id.slice(item.id.indexOf("/") + 1); // class:<folder>/<class>
      } else {
        const dot = item.id.lastIndexOf("."); // <Class>.<Method>
        className = dot >= 0 ? item.id.slice(0, dot) : item.id;
        method = dot >= 0 ? item.id.slice(dot + 1) : undefined;
      }
      const target = isClass
        ? `テストクラス「${className}」(.swift ファイルごと)`
        : `テスト「${item.label}」`;
      const picked = await vscode.window.showWarningMessage(
        `${target}を削除します。この操作は元に戻せません。`,
        { modal: true },
        "削除",
      );
      if (picked !== "削除") {
        return;
      }
      // ファイル削除の前に、そのファイルを開いているエディタを閉じる(削除後にダングリング
      // エディタが残らないように)。クラス削除は必ずファイルごと削除するのでここで閉じる。
      if (isClass) {
        await closeEditorsForFile(file);
      }
      const config = getConfig();
      const args = ["api", "delete-scenario", "--file", file, "--class", className];
      // 関数削除は --method(ファイルは絶対に消えない)、クラス削除は明示の --delete-file。
      // どちらかを必ず渡すことで、誤ってファイルが削除されることを防ぐ(対向: ApiDeleteScenarioCommand)。
      if (method !== undefined) {
        args.push("--method", method);
      } else {
        args.push("--delete-file");
      }
      // 削除中はスピナー(busy)+ 説明で進行中を示す。成功時は refresh でアイテムごと消えるので
      // 復元不要。失敗時は元の状態(@Deleted なら「(削除済み)」)へ戻す。
      item.busy = true;
      const prevDescription = item.description;
      item.description = "削除中…";
      const restoreItem = (): void => {
        item.busy = false;
        item.description = prevDescription;
      };
      let stderr = "";
      let result: CliResult;
      try {
        result = await cli.invoke(config.binaryPath, workspaceRoot, {
          args,
          onLog: (line, stream) => {
            outputChannel.appendLine(`[delete-scenario ${stream}] ${line}`);
            if (stream === "stderr") {
              stderr += `${line}\n`;
            }
          },
        });
      } catch (error) {
        restoreItem();
        void vscode.window.showErrorMessage(
          `ftester: 削除に失敗しました: ${error instanceof Error ? error.message : String(error)}`,
        );
        return;
      }
      if (result.exitCode !== 0) {
        restoreItem();
        void vscode.window.showErrorMessage(
          `ftester: 削除に失敗しました。${stderr.trim() || "出力パネル「ftester」を確認してください。"}`,
        );
        return;
      }
      // メソッド削除はファイルを書き換えるだけ(ファイルは残す)。開いているエディタへ反映する。
      if (method !== undefined) {
        await syncOpenEditorToDisk(file);
      }
      await testTree.refresh();
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
