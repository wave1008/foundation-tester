// stepsView.ts
// 読み取り専用の「ステップ一覧」TreeView(ビュー id: ftesterSteps)。
//
// - `ftester api steps --project <P> --scenario <ID>` を叩いて dry-run 相当のステップ表を
//   取得し、stepsModel.buildStepTree() (vscode 非依存の純関数) でノードモデルに変換して表示する。
// - 表示対象シナリオは2経路で決まる:
//     a. アクティブエディタ追従(既定): カーソル位置のファイル・行から、同ファイル内で
//        カーソル行以下の最も近い methodLine を持つシナリオを testTree.scenarios から逆引きする。
//     b. 明示コマンド `ftester.showSteps`(Test Explorer のシナリオ右クリックから呼べる)。
// - シナリオID+project をキーにキャッシュし、watcher の変更通知(addChangeListener)で
//   キャッシュを破棄して再取得する。表示対象が切り替わった後に届いた古い応答は
//   世代番号(generation)で破棄する。

import * as path from "node:path";
import * as vscode from "vscode";
import { CliSupersededError, type FtesterCli } from "./cli";
import { type FtesterConfig, resolveProjectName } from "./config";
import type { ScenarioInfo, StepRow, StepsResult } from "./model";
import { buildStepTree, type StepTreeSceneNode, type StepTreeStepNode } from "./stepsModel";
import type { FtesterTestTree } from "./testTree";
import type { ScenarioFileWatcher } from "./watcher";

/** クリックでソース行へジャンプするための内部コマンド(コマンドパレットには出さない)。 */
const OPEN_STEP_LOCATION_COMMAND = "ftester.stepsView.openStepLocation";

export function registerStepsView(
  context: vscode.ExtensionContext,
  cli: FtesterCli,
  workspaceRoot: string,
  getConfig: () => FtesterConfig,
  testTree: FtesterTestTree,
  watcher: ScenarioFileWatcher,
  outputChannel: vscode.OutputChannel,
): void {
  const provider = new StepsTreeDataProvider(cli, workspaceRoot, getConfig, outputChannel);
  context.subscriptions.push(provider);

  const treeView = vscode.window.createTreeView("ftesterSteps", {
    treeDataProvider: provider,
    showCollapseAll: true,
  });
  provider.attachTreeView(treeView);
  context.subscriptions.push(treeView);

  const resolveProject = (): string | undefined => {
    const resolution = resolveProjectName(workspaceRoot, getConfig());
    return resolution.kind === "resolved" ? resolution.project : undefined;
  };

  const updateFromEditor = (editor: vscode.TextEditor | undefined): void => {
    if (!editor) {
      return;
    }
    const project = resolveProject();
    if (!project) {
      return;
    }
    const line1 = editor.selection.active.line + 1; // 0起点 → 1起点
    const scenario = findScenarioForPosition(
      testTree.scenarios,
      editor.document.uri.fsPath,
      line1,
    );
    if (scenario) {
      provider.setScenario(scenario.id, project);
    }
  };

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => updateFromEditor(editor)),
    vscode.window.onDidChangeTextEditorSelection((e) => {
      if (e.textEditor === vscode.window.activeTextEditor) {
        updateFromEditor(e.textEditor);
      }
    }),
  );
  // 起動時点で既にエディタが開かれていれば、それに追従して初期表示する。
  updateFromEditor(vscode.window.activeTextEditor);

  context.subscriptions.push(
    vscode.commands.registerCommand(
      OPEN_STEP_LOCATION_COMMAND,
      async (file: string, line: number) => {
        const absolute = path.isAbsolute(file) ? file : path.join(workspaceRoot, file);
        const position = new vscode.Position(Math.max(0, line - 1), 0);
        await vscode.window.showTextDocument(vscode.Uri.file(absolute), {
          selection: new vscode.Range(position, position),
        });
      },
    ),
    vscode.commands.registerCommand("ftester.showSteps", (item?: vscode.TestItem) => {
      if (!item) {
        return;
      }
      const scenario = testTree.scenarios.find((s) => s.id === item.id);
      if (!scenario) {
        void vscode.window.showWarningMessage(
          "ftester: シナリオ(メソッド)を選択してから実行してください。",
        );
        return;
      }
      const project = resolveProject();
      if (!project) {
        void vscode.window.showWarningMessage(
          "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
        );
        return;
      }
      provider.setScenario(scenario.id, project);
      void Promise.resolve(vscode.commands.executeCommand("ftesterSteps.focus")).then(
        undefined,
        () => {
          /* ビューがまだ表示されていない等の理由で失敗しても無視する */
        },
      );
    }),
    vscode.commands.registerCommand("ftester.refreshSteps", () => {
      provider.forceRefresh();
    }),
  );

  context.subscriptions.push(watcher.addChangeListener(() => provider.invalidateCache()));
}

/**
 * scenarios(testTree.scenarios。file は絶対パス)から、指定ファイル・行に対応するシナリオを
 * 逆引きする。同ファイル内で methodLine <= line1 を満たすもののうち、methodLine が
 * 最大のもの(= カーソル行以下で最も近いメソッド宣言)を返す。該当が無ければ undefined。
 */
function findScenarioForPosition(
  scenarios: readonly ScenarioInfo[],
  filePath: string,
  line1: number,
): ScenarioInfo | undefined {
  let best: ScenarioInfo | undefined;
  let bestMethodLine = -1;
  for (const scenario of scenarios) {
    const methodLine = scenario.methodLine;
    if (!scenario.file || methodLine === null) {
      continue;
    }
    if (path.resolve(scenario.file) !== path.resolve(filePath)) {
      continue;
    }
    if (methodLine > line1) {
      continue;
    }
    if (methodLine > bestMethodLine) {
      best = scenario;
      bestMethodLine = methodLine;
    }
  }
  return best;
}

/** ツリーに表示する1ノード分(scene/step/状態メッセージ)。 */
type ViewNode =
  | { readonly type: "empty"; readonly message?: string }
  | { readonly type: "loading" }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "scene"; readonly scene: StepTreeSceneNode }
  | { readonly type: "step"; readonly step: StepTreeStepNode };

type FetchStatus =
  | { readonly state: "loading" }
  | { readonly state: "error"; readonly message: string }
  | { readonly state: "loaded"; readonly steps: readonly StepRow[] };

interface CurrentScenario {
  readonly id: string;
  readonly project: string;
}

const NO_SELECTION_MESSAGE =
  "対象のシナリオが選択されていません。エディタでシナリオ(@Test メソッド)内にカーソルを置くか、" +
  "テストビューでシナリオを右クリックして「ftester: ステップ一覧を表示」を実行してください。";

class StepsTreeDataProvider implements vscode.TreeDataProvider<ViewNode>, vscode.Disposable {
  private readonly emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;

  private treeView: vscode.TreeView<ViewNode> | undefined;
  private current: CurrentScenario | undefined;
  private status: FetchStatus = { state: "loading" };
  private readonly cache = new Map<string, readonly StepRow[]>();
  private generation = 0;

  constructor(
    private readonly cli: FtesterCli,
    private readonly workspaceRoot: string,
    private readonly getConfig: () => FtesterConfig,
    private readonly outputChannel: vscode.OutputChannel,
  ) {}

  dispose(): void {
    this.emitter.dispose();
  }

  attachTreeView(treeView: vscode.TreeView<ViewNode>): void {
    this.treeView = treeView;
    this.updateDescription();
  }

  /** 表示対象シナリオを切り替える。同一シナリオなら何もしない(不要な再取得を避ける)。 */
  setScenario(id: string, project: string): void {
    if (this.current?.id === id && this.current.project === project) {
      return;
    }
    this.current = { id, project };
    this.updateDescription();
    this.refetch();
  }

  /** watcher からの変更通知。キャッシュを破棄し、表示中のシナリオがあれば再取得する。 */
  invalidateCache(): void {
    this.cache.clear();
    if (this.current) {
      this.refetch();
    }
  }

  /** ツールバーの更新ボタン。キャッシュを破棄して強制的に再取得する。 */
  forceRefresh(): void {
    this.cache.clear();
    if (this.current) {
      this.refetch();
    } else {
      this.render();
    }
  }

  private updateDescription(): void {
    if (this.treeView) {
      this.treeView.description = this.current?.id ?? "";
    }
  }

  private refetch(): void {
    const current = this.current;
    if (!current) {
      this.render();
      return;
    }
    const cached = this.cache.get(current.id);
    if (cached) {
      this.status = { state: "loaded", steps: cached };
      this.render();
      return;
    }

    this.status = { state: "loading" };
    this.render();
    const generation = ++this.generation;

    this.fetchSteps(current).then(
      (steps) => {
        if (generation !== this.generation) {
          return; // 表示対象が切り替わった後に届いた古い応答は破棄する
        }
        this.cache.set(current.id, steps);
        this.status = { state: "loaded", steps };
        this.render();
      },
      (error: unknown) => {
        if (error instanceof CliSupersededError) {
          return; // より新しい取得要求に置き換えられた。何もしない。
        }
        if (generation !== this.generation) {
          return;
        }
        const message = error instanceof Error ? error.message : String(error);
        this.status = { state: "error", message };
        this.render();
      },
    );
  }

  private async fetchSteps(current: CurrentScenario): Promise<readonly StepRow[]> {
    const config = this.getConfig();
    const args = ["api", "steps", "--project", current.project, "--scenario", current.id];
    if (!config.buildBeforeRun) {
      args.push("--skip-build");
    }

    const stderrLines: string[] = [];
    const result = await this.cli.invoke(
      config.binaryPath,
      this.workspaceRoot,
      {
        args,
        onLog: (line, stream) => {
          this.outputChannel.appendLine(`[${stream}] ${line}`);
          if (stream === "stderr") {
            stderrLines.push(line);
          }
        },
      },
      "steps",
    );

    if (result.cancelled) {
      throw new Error("ステップ一覧の取得がキャンセルされました。");
    }
    if (result.exitCode !== 0) {
      const summary = stderrLines.slice(-3).join(" / ");
      const suffix = summary.length > 0 ? `: ${summary}` : "";
      throw new Error(
        `ステップ一覧の取得に失敗しました(exit code: ${String(result.exitCode)})${suffix}`,
      );
    }
    const parsed = result.json as StepsResult | undefined;
    if (!parsed || !Array.isArray(parsed.steps)) {
      throw new Error("ステップ一覧の出力を解析できませんでした。");
    }
    return parsed.steps;
  }

  private render(): void {
    this.updateDescription();
    this.emitter.fire();
  }

  getTreeItem(element: ViewNode): vscode.TreeItem {
    switch (element.type) {
      case "empty": {
        const item = new vscode.TreeItem(element.message ?? NO_SELECTION_MESSAGE);
        item.iconPath = new vscode.ThemeIcon("info");
        return item;
      }
      case "loading": {
        const item = new vscode.TreeItem("読み込み中...");
        item.iconPath = new vscode.ThemeIcon("loading~spin");
        return item;
      }
      case "error": {
        const item = new vscode.TreeItem(`エラー: ${element.message}`);
        item.tooltip = element.message;
        item.iconPath = new vscode.ThemeIcon("error");
        return item;
      }
      case "scene": {
        const item = new vscode.TreeItem(
          element.scene.label,
          vscode.TreeItemCollapsibleState.Expanded,
        );
        item.contextValue = "ftesterStepsScene";
        return item;
      }
      case "step": {
        const step = element.step;
        const item = new vscode.TreeItem(step.label, vscode.TreeItemCollapsibleState.None);
        item.description = step.description;
        item.tooltip = step.tooltip;
        item.iconPath = sectionIcon(step.section);
        item.contextValue = "ftesterStepsStep";
        item.command = {
          command: OPEN_STEP_LOCATION_COMMAND,
          title: "ftester: ソースへ移動",
          arguments: [step.file, step.line],
        };
        return item;
      }
    }
  }

  getChildren(element?: ViewNode): ViewNode[] {
    if (element) {
      if (element.type === "scene") {
        return element.scene.steps.map((step) => ({ type: "step", step }));
      }
      return [];
    }

    if (!this.current) {
      return [{ type: "empty" }];
    }
    if (this.status.state === "loading") {
      return [{ type: "loading" }];
    }
    if (this.status.state === "error") {
      return [{ type: "error", message: this.status.message }];
    }

    const scenes = buildStepTree(this.status.steps);
    if (scenes.length === 0) {
      return [{ type: "empty", message: "このシナリオにはステップがありません。" }];
    }
    return scenes.map((scene) => ({ type: "scene", scene }));
  }
}

function sectionIcon(section: StepRow["section"]): vscode.ThemeIcon {
  switch (section) {
    case "condition":
      return new vscode.ThemeIcon("circle-outline");
    case "action":
      return new vscode.ThemeIcon("arrow-right");
    case "expectation":
      return new vscode.ThemeIcon("check");
  }
}
