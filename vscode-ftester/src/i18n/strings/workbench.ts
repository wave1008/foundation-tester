// バッチG 辞書。namespace: workbench.
// 対象ソース: extension.ts, model.ts, stepsView.ts, stepsModel.ts, testTree.ts, config.ts,
//   profileDiagnostics.ts, profileModel.ts, orphanSweep.ts, lastResults.ts, lastResultsSync.ts,
//   reportCodeLens.ts, scenarioReports.ts, ndjson.ts, adbWifiRepair.ts, copyTestName.ts
// キーは "workbench." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const workbenchStrings = {
  "workbench.activate.noWorkspaceLog": {
    ja: "[ftester] フォルダーが開かれていないため初期化を中止しました。foundation-tester リポジトリのフォルダーを開いてから再読み込みしてください。",
    en: "[ftester] No folder is open; aborting initialization. Open the foundation-tester repository folder and reload.",
  },
  "workbench.activate.noWorkspaceWarning": {
    ja: "ftester: フォルダーが開かれていません。リポジトリのフォルダーを開いてください。",
    en: "ftester: No folder is open. Please open the repository folder.",
  },
  "workbench.activate.noProjectsDirLog": {
    ja: "[ftester] {workspaceRoot} に Projects/ が見つからないため初期化しません。",
    en: "[ftester] No Projects/ found under {workspaceRoot}; skipping initialization.",
  },
  "workbench.activate.initializedLog": {
    ja: "[ftester] 初期化しました: {workspaceRoot}",
    en: "[ftester] Initialized: {workspaceRoot}",
  },

  "workbench.filter.enabledStatus": {
    ja: "ftester: 失敗したテストのみ表示します(未実施・成功は除外)",
    en: "ftester: Showing only failed tests (not-run and passed are excluded)",
  },
  "workbench.filter.disabledStatus": {
    ja: "ftester: フィルターを解除しました(全テストを表示)",
    en: "ftester: Filter cleared (showing all tests)",
  },

  "workbench.delete.fileNotFound": {
    ja: "ftester: 削除対象のファイルを特定できませんでした。",
    en: "ftester: Could not determine the file to delete.",
  },
  "workbench.delete.targetClass": {
    ja: "テストクラス「{className}」(.swift ファイルごと)",
    en: "test class \"{className}\" (including its .swift file)",
  },
  "workbench.delete.targetTest": {
    ja: "テスト「{label}」",
    en: "test \"{label}\"",
  },
  "workbench.delete.confirmMessage": {
    ja: "{target}を削除します。この操作は元に戻せません。",
    en: "This will delete {target}. This action cannot be undone.",
  },
  "workbench.delete.confirmButton": {
    ja: "削除",
    en: "Delete",
  },
  "workbench.delete.inProgress": {
    ja: "削除中…",
    en: "Deleting…",
  },
  "workbench.delete.failedWithError": {
    ja: "ftester: 削除に失敗しました: {message}",
    en: "ftester: Delete failed: {message}",
  },
  "workbench.delete.failedGeneric": {
    ja: "ftester: 削除に失敗しました。{detail}",
    en: "ftester: Delete failed. {detail}",
  },
  "workbench.outputPanelHint": {
    ja: "出力パネル「ftester」を確認してください。",
    en: "Check the \"ftester\" output panel.",
  },

  "workbench.selectProject.noProjects": {
    ja: "ftester: Projects/ 配下にテストプロジェクトが見つかりません。",
    en: "ftester: No test projects found under Projects/.",
  },
  "workbench.selectProject.placeholder": {
    ja: "対象のテストプロジェクトを選択してください",
    en: "Select the target test project",
  },
  "workbench.selectProject.setLog": {
    ja: "[ftester] プロジェクトを「{project}」に設定しました。",
    en: "[ftester] Project set to \"{project}\".",
  },

  "workbench.project.unresolvedWarning": {
    ja: "ftester: 対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    en: "ftester: Could not resolve the target test project. Check the ftester.project setting.",
  },

  "workbench.profile.none": {
    ja: "(プロファイルなし)",
    en: "(No profile)",
  },
  "workbench.profile.currentSetting": {
    ja: "現在の設定",
    en: "Current setting",
  },
  "workbench.selectProfile.placeholder": {
    ja: "使用する実行プロファイルを選択してください(Projects/{project}/profiles/runs/ の一覧)",
    en: "Select the run profile to use (from Projects/{project}/profiles/runs/)",
  },
  "workbench.selectProfile.setLog": {
    ja: "[ftester] 実行プロファイルを「{value}」に設定しました。",
    en: "[ftester] Run profile set to \"{value}\".",
  },
  "workbench.selectProfile.setInfo": {
    ja: "ftester: 実行プロファイルを「{value}」に設定しました。",
    en: "ftester: Run profile set to \"{value}\".",
  },

  "workbench.showSteps.noScenario": {
    ja: "ftester: シナリオ(メソッド)を選択してから実行してください。",
    en: "ftester: Select a scenario (test method) before running this.",
  },
  "workbench.stepsView.noSelection": {
    ja: "対象のシナリオが選択されていません。エディタでシナリオ(@Test メソッド)内にカーソルを置くか、テストビューでシナリオを右クリックして「ftester: ステップ一覧を表示」を実行してください。",
    en: "No scenario is selected. Place the cursor inside a scenario (@Test method) in the editor, or right-click a scenario in the test view and run \"ftester: Show Steps\".",
  },
  "workbench.stepsView.fetchCancelled": {
    ja: "ステップ一覧の取得がキャンセルされました。",
    en: "Fetching the step list was cancelled.",
  },
  "workbench.stepsView.fetchFailed": {
    ja: "ステップ一覧の取得に失敗しました(exit code: {exitCode}){suffix}",
    en: "Failed to fetch the step list (exit code: {exitCode}){suffix}",
  },
  "workbench.stepsView.parseFailed": {
    ja: "ステップ一覧の出力を解析できませんでした。",
    en: "Could not parse the step list output.",
  },
  "workbench.stepsView.openSourceCommandTitle": {
    ja: "ftester: ソースへ移動",
    en: "ftester: Go to Source",
  },
  "workbench.stepsView.noSteps": {
    ja: "このシナリオにはステップがありません。",
    en: "This scenario has no steps.",
  },

  "workbench.common.loading": {
    ja: "読み込み中...",
    en: "Loading...",
  },
  "workbench.common.errorPrefix": {
    ja: "エラー: {message}",
    en: "Error: {message}",
  },

  "workbench.stepsModel.sectionLabel": {
    ja: "区分: {section}",
    en: "Section: {section}",
  },

  "workbench.testTree.noProjectsLog": {
    ja: "[ftester] Projects/ 配下にテストプロジェクトが見つかりません。",
    en: "[ftester] No test projects found under Projects/.",
  },
  "workbench.testTree.listScenariosExitLog": {
    ja: "[ftester] list-scenarios が exit code {exitCode} で終了しました。",
    en: "[ftester] list-scenarios exited with code {exitCode}.",
  },
  "workbench.testTree.listScenariosFailedWarning": {
    ja: "ftester: シナリオ一覧の取得に失敗しました。出力パネル「ftester」を確認してください。",
    en: "ftester: Failed to fetch the scenario list. Check the \"ftester\" output panel.",
  },
  "workbench.testTree.listScenariosParseFailedLog": {
    ja: "[ftester] list-scenarios の出力を解析できませんでした。",
    en: "[ftester] Could not parse the list-scenarios output.",
  },
  "workbench.testTree.ambiguousProjectWarning": {
    ja: "ftester: 複数のテストプロジェクトが見つかりました({candidates})。ftester.project 設定で対象を指定するか、プロジェクトを選択してください。",
    en: "ftester: Multiple test projects were found ({candidates}). Specify the target in the ftester.project setting, or select a project.",
  },
  "workbench.testTree.selectProjectButton": {
    ja: "プロジェクトを選択",
    en: "Select Project",
  },
  "workbench.testTree.cliLaunchFailedWarning": {
    ja: "ftester CLI を起動できませんでした({binaryPath})。\"swift build --product ftester\" でビルド済みか確認してください。",
    en: "Could not launch the ftester CLI ({binaryPath}). Check whether it has been built with \"swift build --product ftester\".",
  },
  "workbench.testTree.deletedDescription": {
    ja: "(削除済み)",
    en: "(Deleted)",
  },

  "workbench.profileDiag.unresolvedProjectLog": {
    ja: "[ftester] プロファイル検証: 対象のテストプロジェクトを解決できませんでした。",
    en: "[ftester] Profile validation: could not resolve the target test project.",
  },
  "workbench.profileDiag.runFailedLog": {
    ja: "[ftester] プロファイル検証の実行に失敗しました: {error}",
    en: "[ftester] Profile validation failed to run: {error}",
  },
  "workbench.profileDiag.parseFailedLog": {
    ja: "[ftester] プロファイル検証の出力を解析できませんでした(exit code: {exitCode})。",
    en: "[ftester] Could not parse the profile validation output (exit code: {exitCode}).",
  },
  "workbench.profileDiag.validateFailedWarning": {
    ja: "ftester: プロファイルの検証に失敗しました。対象プロジェクト(ftester.project)や出力パネル「ftester」を確認してください。",
    en: "ftester: Profile validation failed. Check the target project (ftester.project) setting or the \"ftester\" output panel.",
  },
  "workbench.profileDiag.validatedInfo": {
    ja: "ftester: プロファイルを検証しました({total}件中 エラー {errorFiles}件・警告 {warningOnlyFiles}件・問題なし {cleanFiles}件)。",
    en: "ftester: Validated profiles ({total} total — {errorFiles} error(s), {warningOnlyFiles} warning-only, {cleanFiles} clean).",
  },

  "workbench.orphanSweep.detectFailedLog": {
    ja: "[ftester] 孤児プロセスの検出に失敗しました(ps): {error}",
    en: "[ftester] Failed to detect orphan processes (ps): {error}",
  },
  "workbench.orphanSweep.killFailedLog": {
    ja: "[ftester] 孤児プロセス(PID {pid})の終了に失敗しました: {error}",
    en: "[ftester] Failed to terminate orphan process (PID {pid}): {error}",
  },
  "workbench.orphanSweep.sweptLog": {
    ja: "[ftester] 孤児化した常駐プロセスを掃除しました: PID {pids}",
    en: "[ftester] Cleaned up orphaned resident processes: PID {pids}",
  },

  "workbench.lastResults.cliFailedNoReport": {
    ja: "CLI 実行で失敗(詳細はレポート参照)",
    en: "CLI run failed (see report for details)",
  },
  "workbench.lastResults.cliFailedWithReport": {
    ja: "CLI 実行で失敗 — [レポートを開く](command:ftester.openScenarioReport?{args})",
    en: "CLI run failed — [Open report](command:ftester.openScenarioReport?{args})",
  },
  "workbench.lastResults.testRunName": {
    ja: "CLI実行結果",
    en: "CLI run results",
  },
  "workbench.lastResults.appliedLog": {
    ja: "[lastResultsSync] 反映 {count}件",
    en: "[lastResultsSync] Applied {count} result(s)",
  },

  "workbench.reportCodeLens.title": {
    ja: "❌ 前回失敗 — レポートを開く",
    en: "❌ Failed last run — Open report",
  },
  "workbench.language.reloadPrompt": {
    ja: "ftester: 表示言語の設定を変更しました。ウィンドウを再読み込みすると完全に反映されます。",
    en: "ftester: The display language setting changed. Reload the window to fully apply it.",
  },
  "workbench.language.reloadButton": { ja: "再読み込み", en: "Reload Window" },
} satisfies MessageDict;
