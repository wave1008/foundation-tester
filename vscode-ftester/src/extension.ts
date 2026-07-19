// extension.ts
// 拡張のエントリポイント。activate() で各コンポーネントを組み立てて登録する。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { type CliResult, FtesterCli } from "./cli";
import { checkFtesterCompat } from "./compatCheck";
import {
  type FtesterConfig,
  listProjectCandidates,
  listRunProfileNames,
  readConfig,
  resolveProjectName,
  resolveWorkspaceRoot,
} from "./config";
import { registerDashboardPanel } from "./dashboardPanel";
import { registerDebugAdapter } from "./debugConfig";
import { registerHealReviewPanel } from "./healReviewPanel";
import { initI18n, setLocaleFromConfig, t } from "./i18n";
import { registerLastResultsSync } from "./lastResultsSync";
import { registerLivePanel } from "./livePanel";
import { registerMonitorPanel } from "./monitorPanel";
import { sweepOrphans } from "./orphanSweep";
import { registerProfileDiagnostics } from "./profileDiagnostics";
import { registerReportCodeLens } from "./reportCodeLens";
import { RunEventBus } from "./runEventBus";
import { isRunActive, registerRunHandler } from "./runHandler";
import { registerStepsView } from "./stepsView";
import { FtesterTestTree, unhideAllTests } from "./testTree";
import { ScenarioFileWatcher } from "./watcher";

export function activate(context: vscode.ExtensionContext): void {
  // UI 文字列の locale を確定してから各コンポーネントを組み立てる(以降の t() が正しい言語を返す)。
  initI18n();

  const outputChannel = vscode.window.createOutputChannel("ftester");
  context.subscriptions.push(outputChannel);

  // 孤児化した常駐プロセス(reload window 等で拡張ホストが即死し PPID=1 になったもの)の掃除。
  // best-effort・fire-and-forget(失敗しても activate を止めない。orphanSweep.ts 参照)。
  void sweepOrphans((message) => outputChannel.appendLine(message));

  const workspaceRoot = resolveWorkspaceRoot();
  if (!workspaceRoot) {
    // 無言で終わると「ビューに provider が無い」という分かりにくい表示になるため理由を明示する。
    outputChannel.appendLine(t("workbench.activate.noWorkspaceLog"));
    void vscode.window.showWarningMessage(t("workbench.activate.noWorkspaceWarning"));
    return;
  }
  if (!hasProjectsDirectory(workspaceRoot)) {
    // ftester のテストプロジェクトを持たないリポジトリでは登録しない。
    outputChannel.appendLine(t("workbench.activate.noProjectsDirLog", { workspaceRoot }));
    return;
  }
  outputChannel.appendLine(t("workbench.activate.initializedLog", { workspaceRoot }));

  const cli = new FtesterCli(outputChannel);
  const getConfig = (): FtesterConfig => readConfig(workspaceRoot);

  // CLI ↔ 拡張のプロトコル版照合(compatCheck.ts)。activate をブロックしない fire-and-forget。
  void checkFtesterCompat(getConfig().binaryPath, workspaceRoot, outputChannel, (proc) => {
    context.subscriptions.push({ dispose: () => proc.kill() });
  }).catch((error) => {
    outputChannel.appendLine(`[ftester] ${error instanceof Error ? error.message : String(error)}`);
  });

  // runHandler と monitorPanel へ配信する共有インスタンス(runEventBus.ts 参照)。
  const runEventBus = new RunEventBus();

  const testTree = registerTestTree(context, cli, workspaceRoot, getConfig, outputChannel);
  const watcher = registerWatcher(context, workspaceRoot, testTree);
  registerCommands(context, cli, workspaceRoot, testTree, getConfig, outputChannel);

  // 失敗テストの「レポートを開く」CodeLens。last-results 変化(lastResultsSync)・GUI 実行終了
  // (runHandler)のどちらでも再描画させる(reportCodeLens.ts 冒頭コメント参照)。
  const reportCodeLens = registerReportCodeLens({
    controller: testTree.controller,
    workspaceRoot,
    getConfig,
  });
  context.subscriptions.push(reportCodeLens);

  // 実行結果が変化したときの共通処理。showOnlyFailedTests が ON の間は合否の変化で表示対象も
  // 変わる(新規失敗は現れ、成功に転じたものは消える)ためツリーを再構築する。
  const onResultsChanged = (): void => {
    reportCodeLens.refresh();
    unhideAllTests();
    if (getConfig().showOnlyFailedTests && !isRunActive()) {
      testTree.rebuildFromLastData();
    }
  };

  const lastResultsSync = registerLastResultsSync({
    controller: testTree.controller,
    workspaceRoot,
    getConfig,
    isGuiRunActive: isRunActive,
    outputChannel,
    onResultsApplied: onResultsChanged,
  });
  context.subscriptions.push(lastResultsSync);
  // registerRunHandler の Run Test 前ライブパネル連携(prepareForRun)と registerMonitorPanel の
  // openLiveForDevice(デバイスタイル右クリック連携)の両方に使うため先に生成する。
  const livePanel = registerLivePanel(context, workspaceRoot, getConfig, outputChannel, cli, testTree, runEventBus);
  registerRunHandler(
    context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel, runEventBus,
    (executedScenarioIds) => {
      // absorb しないと GUI 実行分が次 tick で合成 run(出力ゼロ)になり TEST RESULTS の
      // 最新実行を乗っ取る(lastResultsSync.ts 冒頭コメント参照)。
      lastResultsSync.absorb(executedScenarioIds);
      onResultsChanged();
    },
    livePanel.prepareForRun,
  );
  registerDebugAdapter(context, workspaceRoot, getConfig, outputChannel);
  registerStepsView(context, cli, workspaceRoot, getConfig, testTree, watcher, outputChannel);
  registerMonitorPanel(context, workspaceRoot, getConfig, outputChannel, runEventBus, livePanel.openForDevice);
  registerHealReviewPanel(context, workspaceRoot, getConfig, outputChannel, runEventBus, cli);
  registerDashboardPanel(context, workspaceRoot, getConfig, outputChannel, runEventBus);
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
  // Test Explorer タイトルバーのトグルボタン(package.json view/title の enable/disable ペア)の
  // 表示切替に使う context key。設定 ftester.showOnlyFailedTests と常に同期させる
  // (設定エディタから直接変更された場合も onDidChangeConfiguration で追従し、ツリーも再構築)。
  const syncFailedFilterContext = (): void => {
    void vscode.commands.executeCommand(
      "setContext",
      "ftester.failedTestsFilterEnabled",
      getConfig().showOnlyFailedTests,
    );
  };
  syncFailedFilterContext();
  const setFailedFilter = async (value: boolean): Promise<void> => {
    await vscode.workspace
      .getConfiguration("ftester")
      .update("showOnlyFailedTests", value, vscode.ConfigurationTarget.Global);
    vscode.window.setStatusBarMessage(
      value ? t("workbench.filter.enabledStatus") : t("workbench.filter.disabledStatus"),
      3000,
    );
  };

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("ftester.showOnlyFailedTests")) {
        return;
      }
      syncFailedFilterContext();
      // 実行中は TestRun が既存アイテムを参照しているため再構築しない(実行終了時の
      // onRunFinished 経由で追いつく)。
      if (!isRunActive()) {
        testTree.rebuildFromLastData();
      }
    }),
    // 表示言語(ftester.language)変更: locale を切り替え、テストツリーは即時に再翻訳する。
    // webview パネルや package.nls(コマンド/設定説明)は再レンダー配線を持たないため、完全反映には
    // ウィンドウ再読み込みが要る。案内を出してユーザーに委ねる。
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("ftester.language")) {
        return;
      }
      setLocaleFromConfig();
      if (!isRunActive()) {
        testTree.rebuildFromLastData();
      }
      void vscode.window
        .showInformationMessage(t("workbench.language.reloadPrompt"), t("workbench.language.reloadButton"))
        .then((picked) => {
          if (picked === t("workbench.language.reloadButton")) {
            void vscode.commands.executeCommand("workbench.action.reloadWindow");
          }
        });
    }),
    vscode.commands.registerCommand("ftester.enableFailedTestsFilter", () => {
      void setFailedFilter(true);
    }),
    vscode.commands.registerCommand("ftester.disableFailedTestsFilter", () => {
      void setFailedFilter(false);
    }),
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
        void vscode.window.showErrorMessage(t("workbench.delete.fileNotFound"));
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
        ? t("workbench.delete.targetClass", { className })
        : t("workbench.delete.targetTest", { label: item.label });
      const deleteButtonLabel = t("workbench.delete.confirmButton");
      const picked = await vscode.window.showWarningMessage(
        t("workbench.delete.confirmMessage", { target }),
        { modal: true },
        deleteButtonLabel,
      );
      if (picked !== deleteButtonLabel) {
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
      item.description = t("workbench.delete.inProgress");
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
          t("workbench.delete.failedWithError", {
            message: error instanceof Error ? error.message : String(error),
          }),
        );
        return;
      }
      if (result.exitCode !== 0) {
        restoreItem();
        void vscode.window.showErrorMessage(
          t("workbench.delete.failedGeneric", {
            detail: stderr.trim() || t("workbench.outputPanelHint"),
          }),
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
        void vscode.window.showWarningMessage(t("workbench.selectProject.noProjects"));
        return;
      }
      const picked = await vscode.window.showQuickPick(candidates, {
        placeHolder: t("workbench.selectProject.placeholder"),
      });
      if (!picked) {
        return;
      }
      await vscode.workspace
        .getConfiguration("ftester")
        .update("project", picked, vscode.ConfigurationTarget.Workspace);
      outputChannel.appendLine(t("workbench.selectProject.setLog", { project: picked }));
      void testTree.refresh();
    }),
    vscode.commands.registerCommand("ftester.selectProfile", async () => {
      const config = getConfig();
      const resolution = resolveProjectName(workspaceRoot, config);
      if (resolution.kind !== "resolved") {
        void vscode.window.showWarningMessage(t("workbench.project.unresolvedWarning"));
        return;
      }
      const names = listRunProfileNames(workspaceRoot, resolution.project);
      const NONE_LABEL = t("workbench.profile.none");
      const currentSettingLabel = t("workbench.profile.currentSetting");
      const items: vscode.QuickPickItem[] = [
        {
          label: config.profile === "" ? `$(check) ${NONE_LABEL}` : NONE_LABEL,
          description: config.profile === "" ? currentSettingLabel : undefined,
        },
        ...names.map((name) => ({
          label: config.profile === name ? `$(check) ${name}` : name,
          description: config.profile === name ? currentSettingLabel : undefined,
        })),
      ];
      const picked = await vscode.window.showQuickPick(items, {
        placeHolder: t("workbench.selectProfile.placeholder", { project: resolution.project }),
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
      outputChannel.appendLine(t("workbench.selectProfile.setLog", { value: displayValue }));
      void vscode.window.showInformationMessage(t("workbench.selectProfile.setInfo", { value: displayValue }));
    }),
  );
}
