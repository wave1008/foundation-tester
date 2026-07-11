// testTree.ts
// ftester のシナリオを VS Code TestController ツリーとして表示する。
// 階層は folder → class → @Test メソッド(leaf)。folder が無いシナリオは class をルート直下に置く。
//
// refresh() は list-scenarios を叩いてツリーを全再構築する。並行 refresh 時は世代番号
// (generation)で古い応答の反映を破棄する。

import * as vscode from "vscode";
import { type CliResult, CliSupersededError, type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import type { ListScenariosResult, ScenarioInfo } from "./model";

/** @Deleted シナリオに付与する TestTag(runHandler.ts の対象解決でも参照する)。 */
export const DELETED_TAG = new vscode.TestTag("deleted");

/** folder ノード id / class ノード id の衝突回避用プレフィックス。 */
function folderId(folderName: string): string {
  return `folder:${folderName}`;
}
function classId(folderName: string | null, className: string): string {
  return `class:${folderName ?? ""}/${className}`;
}

export class FtesterTestTree implements vscode.Disposable {
  readonly controller: vscode.TestController;
  private generation = 0;
  /** 直近の refresh() で取得したシナリオ一覧(stepsView.ts のエディタ追従の逆引きに使う)。 */
  private lastScenarios: ScenarioInfo[] = [];

  constructor(
    private readonly cli: FtesterCli,
    private readonly getWorkspaceRoot: () => string | undefined,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
  ) {
    this.controller = vscode.tests.createTestController("ftester", "ftester");
    this.controller.refreshHandler = () => this.refresh();
  }

  dispose(): void {
    this.controller.dispose();
  }

  /** 直近の refresh() で取得したシナリオ一覧(file は絶対パス)。未取得なら空配列。 */
  get scenarios(): readonly ScenarioInfo[] {
    return this.lastScenarios;
  }

  async refresh(): Promise<void> {
    const workspaceRoot = this.getWorkspaceRoot();
    if (!workspaceRoot) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(workspaceRoot, config);

    if (resolution.kind === "none") {
      this.outputChannel.appendLine(
        "[ftester] Projects/ 配下にテストプロジェクトが見つかりません。",
      );
      return;
    }
    if (resolution.kind === "ambiguous") {
      void this.promptAmbiguousProject(resolution.candidates);
      return;
    }

    const project = resolution.project;
    const generation = ++this.generation;
    const args = ["api", "list-scenarios", "--project", project];
    if (!config.buildBeforeRun) {
      args.push("--skip-build");
    }

    let result: CliResult;
    try {
      result = await this.cli.invoke(
        config.binaryPath,
        workspaceRoot,
        {
          args,
          onLog: (line, stream) => this.outputChannel.appendLine(`[${stream}] ${line}`),
        },
        "list-scenarios",
      );
    } catch (error) {
      if (error instanceof CliSupersededError) {
        return; // より新しい refresh 要求に置き換えられた。何もしない。
      }
      this.reportInvocationError(error, config.binaryPath);
      return;
    }

    if (generation !== this.generation) {
      return; // 古い応答は破棄する
    }
    if (result.cancelled) {
      return;
    }
    if (result.exitCode !== 0) {
      this.outputChannel.appendLine(
        `[ftester] list-scenarios が exit code ${String(result.exitCode)} で終了しました。`,
      );
      void vscode.window.showWarningMessage(
        "ftester: シナリオ一覧の取得に失敗しました。出力パネル「ftester」を確認してください。",
      );
      return;
    }

    const parsed = result.json as ListScenariosResult | undefined;
    if (!parsed || !Array.isArray(parsed.scenarios)) {
      this.outputChannel.appendLine("[ftester] list-scenarios の出力を解析できませんでした。");
      return;
    }
    this.rebuildTree(parsed);
  }

  private async promptAmbiguousProject(candidates: string[]): Promise<void> {
    const choice = await vscode.window.showWarningMessage(
      `ftester: 複数のテストプロジェクトが見つかりました(${candidates.join(", ")})。` +
        "ftester.project 設定で対象を指定するか、プロジェクトを選択してください。",
      "プロジェクトを選択",
    );
    if (choice === "プロジェクトを選択") {
      await vscode.commands.executeCommand("ftester.selectProject");
    }
  }

  private reportInvocationError(error: unknown, binaryPath: string): void {
    const message = error instanceof Error ? error.message : String(error);
    this.outputChannel.appendLine(`[ftester] ${message}`);
    void vscode.window.showWarningMessage(
      `ftester CLI を起動できませんでした(${binaryPath})。` +
        '"swift build --product ftester" でビルド済みか確認してください。',
    );
  }

  private rebuildTree(data: ListScenariosResult): void {
    this.lastScenarios = data.scenarios;
    this.controller.items.replace([]);

    const folderNodes = new Map<string, vscode.TestItem>();
    const classNodes = new Map<string, vscode.TestItem>();

    const getFolderNode = (folderName: string | null): vscode.TestItem | undefined => {
      if (folderName === null) {
        return undefined;
      }
      const existing = folderNodes.get(folderName);
      if (existing) {
        return existing;
      }
      const node = this.controller.createTestItem(folderId(folderName), folderName);
      folderNodes.set(folderName, node);
      this.controller.items.add(node);
      return node;
    };

    const getClassNode = (scenario: ScenarioInfo, className: string): vscode.TestItem => {
      const key = classId(scenario.folder, className);
      const existing = classNodes.get(key);
      if (existing) {
        return existing;
      }
      const uri = scenario.file ? vscode.Uri.file(scenario.file) : undefined;
      const node = this.controller.createTestItem(key, className, uri);
      if (scenario.classLine !== null) {
        const line = Math.max(0, scenario.classLine - 1); // 1起点 → 0起点
        node.range = new vscode.Range(line, 0, line, 0);
      }
      classNodes.set(key, node);
      const folderNode = getFolderNode(scenario.folder);
      (folderNode ? folderNode.children : this.controller.items).add(node);
      return node;
    };

    for (const scenario of data.scenarios) {
      const className = scenario.id.split(".")[0] ?? scenario.id;
      const classNode = getClassNode(scenario, className);

      const uri = scenario.file ? vscode.Uri.file(scenario.file) : undefined;
      const leaf = this.controller.createTestItem(scenario.id, scenario.title, uri);
      if (scenario.methodLine !== null) {
        const line = Math.max(0, scenario.methodLine - 1); // 1起点 → 0起点
        leaf.range = new vscode.Range(line, 0, line, 0);
      }
      if (scenario.deleted) {
        leaf.description = "(削除済み)";
        leaf.tags = [DELETED_TAG];
      }
      classNode.children.add(leaf);
    }
  }
}
