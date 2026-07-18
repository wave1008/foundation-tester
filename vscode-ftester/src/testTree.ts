// testTree.ts
// ftester のシナリオを VS Code TestController ツリーとして表示する。
// 階層は folder → class → @Test メソッド(leaf)。folder が無いシナリオは class をルート直下に置く。
//
// refresh() は list-scenarios を叩いてツリーを全再構築する。並行 refresh 時は世代番号
// (generation)で古い応答の反映を破棄する。

import * as vscode from "vscode";
import { type CliResult, CliSupersededError, type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import { t } from "./i18n";
import { lastResultsDir, lookupKey, readFailedScenarioIds } from "./lastResults";
import type { ListScenariosResult, ScenarioInfo } from "./model";

/** @Deleted シナリオに付与する TestTag(runHandler.ts の対象解決でも参照する)。 */
export const DELETED_TAG = new vscode.TestTag("deleted");

/** VSCode 本体の「Hide Test」の実質無効化。メニュー項目は拡張から除去できないため、非表示状態を
 * 常時解除する(activate 時の初回 refresh とツリー再構築のたび。extension.ts の結果反映時も呼ぶ)。 */
export function unhideAllTests(): void {
  void vscode.commands.executeCommand("testing.unhideAllTests").then(undefined, () => {
    // コマンドが無い環境(将来の本体変更)でも他機能に影響させない
  });
}

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
  /** 直近の refresh() で取得したシナリオ一覧(stepsView.ts のエディタ追従の逆引きに使う)。
   * showOnlyFailedTests フィルターに関わらず常に全件を保持する。 */
  private lastScenarios: ScenarioInfo[] = [];
  /** 直近の list-scenarios 結果。フィルター切替時に CLI を叩き直さず再構築するために保持する。 */
  private lastData: ListScenariosResult | undefined;

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

  /** showOnlyFailedTests の切替・実行結果の変化後に、CLI を叩き直さず直近データからツリーを
   * 再構築する(未取得なら refresh() に委ねる)。実行中(TestRun がアイテムを参照している間)は
   * 呼ばないこと(呼び出し側 extension.ts が isRunActive でガードする)。 */
  rebuildFromLastData(): void {
    if (this.lastData) {
      this.rebuildTree(this.lastData);
    } else {
      void this.refresh();
    }
  }

  /** showOnlyFailedTests が ON なら失敗シナリオ id(lookupKey 正規化済み)の集合、OFF なら
   * undefined(=フィルターなし)。 */
  private resolveFailedFilter(): Set<string> | undefined {
    const workspaceRoot = this.getWorkspaceRoot();
    if (!workspaceRoot || !this.getConfig().showOnlyFailedTests) {
      return undefined;
    }
    const resolution = resolveProjectName(workspaceRoot, this.getConfig());
    if (resolution.kind !== "resolved") {
      return undefined;
    }
    return readFailedScenarioIds(lastResultsDir(workspaceRoot, resolution.project));
  }

  async refresh(): Promise<void> {
    const workspaceRoot = this.getWorkspaceRoot();
    if (!workspaceRoot) {
      return;
    }
    const config = this.getConfig();
    const resolution = resolveProjectName(workspaceRoot, config);

    if (resolution.kind === "none") {
      this.outputChannel.appendLine(t("workbench.testTree.noProjectsLog"));
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
        t("workbench.testTree.listScenariosExitLog", { exitCode: String(result.exitCode) }),
      );
      void vscode.window.showWarningMessage(t("workbench.testTree.listScenariosFailedWarning"));
      return;
    }

    const parsed = result.json as ListScenariosResult | undefined;
    if (!parsed || !Array.isArray(parsed.scenarios)) {
      this.outputChannel.appendLine(t("workbench.testTree.listScenariosParseFailedLog"));
      return;
    }
    this.rebuildTree(parsed);
  }

  private async promptAmbiguousProject(candidates: string[]): Promise<void> {
    const selectProjectLabel = t("workbench.testTree.selectProjectButton");
    const choice = await vscode.window.showWarningMessage(
      t("workbench.testTree.ambiguousProjectWarning", { candidates: candidates.join(", ") }),
      selectProjectLabel,
    );
    if (choice === selectProjectLabel) {
      await vscode.commands.executeCommand("ftester.selectProject");
    }
  }

  private reportInvocationError(error: unknown, binaryPath: string): void {
    const message = error instanceof Error ? error.message : String(error);
    this.outputChannel.appendLine(`[ftester] ${message}`);
    void vscode.window.showWarningMessage(
      t("workbench.testTree.cliLaunchFailedWarning", { binaryPath }),
    );
  }

  private rebuildTree(data: ListScenariosResult): void {
    this.lastData = data;
    this.lastScenarios = data.scenarios;
    const failedFilter = this.resolveFailedFilter();
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

    const getClassNode = (
      folder: string | null,
      className: string,
      file: string | null | undefined,
      classLine: number | null,
    ): vscode.TestItem => {
      const key = classId(folder, className);
      const existing = classNodes.get(key);
      if (existing) {
        return existing;
      }
      const uri = file ? vscode.Uri.file(file) : undefined;
      const node = this.controller.createTestItem(key, className, uri);
      if (classLine !== null) {
        const line = Math.max(0, classLine - 1); // 1起点 → 0起点
        node.range = new vscode.Range(line, 0, line, 0);
      }
      classNodes.set(key, node);
      const folderNode = getFolderNode(folder);
      (folderNode ? folderNode.children : this.controller.items).add(node);
      return node;
    };

    // フィルター ON のときは失敗シナリオだけ leaf を作る(未実施・成功は除外)。
    const scenarios = failedFilter
      ? data.scenarios.filter((scenario) => failedFilter.has(lookupKey(scenario.id)))
      : data.scenarios;

    for (const scenario of scenarios) {
      const className = scenario.id.split(".")[0] ?? scenario.id;
      const classNode = getClassNode(scenario.folder, className, scenario.file, scenario.classLine);

      const uri = scenario.file ? vscode.Uri.file(scenario.file) : undefined;
      const leaf = this.controller.createTestItem(scenario.id, scenario.title, uri);
      if (scenario.methodLine !== null) {
        const line = Math.max(0, scenario.methodLine - 1); // 1起点 → 0起点
        leaf.range = new vscode.Range(line, 0, line, 0);
      }
      if (scenario.deleted) {
        leaf.description = t("workbench.testTree.deletedDescription");
        leaf.tags = [DELETED_TAG];
      }
      classNode.children.add(leaf);
    }

    // 空クラス(@Test なし)は class ノードだけ作る(子リーフ無し)。唯一の関数を消しても
    // ファイルが残っていることをツリーで示すため(対向: list-scenarios の emptyClasses)。
    // フィルター ON のときは未実施扱いで出さない。
    if (!failedFilter) {
      for (const empty of data.emptyClasses ?? []) {
        getClassNode(empty.folder, empty.className, empty.file, empty.classLine);
      }
    }

    unhideAllTests();
  }
}
