// バッチG 辞書。namespace: workbench.
// 対象ソース: extension.ts, model.ts, stepsView.ts, stepsModel.ts, testTree.ts, config.ts,
//   profileDiagnostics.ts, profileModel.ts, orphanSweep.ts, lastResults.ts, lastResultsSync.ts,
//   reportCodeLens.ts, scenarioReports.ts, ndjson.ts, adbWifiRepair.ts, copyTestName.ts
// キーは "workbench." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const workbenchStrings = {
  "workbench.activate.noWorkspaceLog": {
    ja: "[fleetest] フォルダーが開かれていないため初期化を中止しました。foundation-tester リポジトリのフォルダーを開いてから再読み込みしてください。",
    en: "[fleetest] No folder is open; aborting initialization. Open the foundation-tester repository folder and reload.",
  },
  "workbench.activate.noWorkspaceWarning": {
    ja: "fleetest: フォルダーが開かれていません。リポジトリのフォルダーを開いてください。",
    en: "fleetest: No folder is open. Please open the repository folder.",
  },
  "workbench.activate.noProjectsDirLog": {
    ja: "[fleetest] {workspaceRoot} に TestProjects/ が見つからないため初期化しません。",
    en: "[fleetest] No TestProjects/ found under {workspaceRoot}; skipping initialization.",
  },
  "workbench.activate.initializedLog": {
    ja: "[fleetest] 初期化しました: {workspaceRoot}",
    en: "[fleetest] Initialized: {workspaceRoot}",
  },

  "workbench.filter.enabledStatus": {
    ja: "fleetest: 失敗したテストのみ表示します(未実施・成功は除外)",
    en: "fleetest: Showing only failed tests (not-run and passed are excluded)",
  },
  "workbench.filter.disabledStatus": {
    ja: "fleetest: フィルターを解除しました(全テストを表示)",
    en: "fleetest: Filter cleared (showing all tests)",
  },

  "workbench.delete.fileNotFound": {
    ja: "fleetest: 削除対象のファイルを特定できませんでした。",
    en: "fleetest: Could not determine the file to delete.",
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
    ja: "fleetest: 削除に失敗しました: {message}",
    en: "fleetest: Delete failed: {message}",
  },
  "workbench.delete.failedGeneric": {
    ja: "fleetest: 削除に失敗しました。{detail}",
    en: "fleetest: Delete failed. {detail}",
  },
  "workbench.outputPanelHint": {
    ja: "出力パネル「fleetest」を確認してください。",
    en: "Check the \"fleetest\" output panel.",
  },

  "workbench.selectProject.noProjects": {
    ja: "fleetest: TestProjects/ 配下にテストプロジェクトが見つかりません。",
    en: "fleetest: No test projects found under TestProjects/.",
  },
  "workbench.selectProject.placeholder": {
    ja: "対象のテストプロジェクトを選択してください",
    en: "Select the target test project",
  },
  "workbench.selectProject.setLog": {
    ja: "[fleetest] プロジェクトを「{project}」に設定しました。",
    en: "[fleetest] Project set to \"{project}\".",
  },

  "workbench.project.unresolvedWarning": {
    ja: "fleetest: 対象のテストプロジェクトを解決できませんでした。fleetest.project 設定を確認してください。",
    en: "fleetest: Could not resolve the target test project. Check the fleetest.project setting.",
  },

    "workbench.profile.clearedForProject": {
    ja: "実行プロファイル「{profile}」は {project} に無いため選択を外しました。プロファイルを選び直してください。",
    en: "Run profile \"{profile}\" does not exist in {project}, so the selection was cleared. Pick one again.",
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
    ja: "使用する実行プロファイルを選択してください(TestProjects/{project}/profiles/runs/ の一覧)",
    en: "Select the run profile to use (from TestProjects/{project}/profiles/runs/)",
  },
  "workbench.selectProfile.setLog": {
    ja: "[fleetest] 実行プロファイルを「{value}」に設定しました。",
    en: "[fleetest] Run profile set to \"{value}\".",
  },
  "workbench.selectProfile.setInfo": {
    ja: "fleetest: 実行プロファイルを「{value}」に設定しました。",
    en: "fleetest: Run profile set to \"{value}\".",
  },

  "workbench.showSteps.noScenario": {
    ja: "fleetest: シナリオ(メソッド)を選択してから実行してください。",
    en: "fleetest: Select a scenario (test method) before running this.",
  },
  "workbench.stepsView.noSelection": {
    ja: "対象のシナリオが選択されていません。エディタでシナリオ(@Test メソッド)内にカーソルを置くか、テストビューでシナリオを右クリックして「fleetest: ステップ一覧を表示」を実行してください。",
    en: "No scenario is selected. Place the cursor inside a scenario (@Test method) in the editor, or right-click a scenario in the test view and run \"fleetest: Show Steps\".",
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
    ja: "fleetest: ソースへ移動",
    en: "fleetest: Go to Source",
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
    ja: "[fleetest] TestProjects/ 配下にテストプロジェクトが見つかりません。",
    en: "[fleetest] No test projects found under TestProjects/.",
  },
  "workbench.testTree.listScenariosExitLog": {
    ja: "[fleetest] list-scenarios が exit code {exitCode} で終了しました。",
    en: "[fleetest] list-scenarios exited with code {exitCode}.",
  },
  "workbench.testTree.listScenariosFailedWarning": {
    ja: "fleetest: シナリオ一覧の取得に失敗しました。出力パネル「fleetest」を確認してください。",
    en: "fleetest: Failed to fetch the scenario list. Check the \"fleetest\" output panel.",
  },
  "workbench.testTree.listScenariosParseFailedLog": {
    ja: "[fleetest] list-scenarios の出力を解析できませんでした。",
    en: "[fleetest] Could not parse the list-scenarios output.",
  },
  "workbench.testTree.ambiguousProjectWarning": {
    ja: "fleetest: 複数のテストプロジェクトが見つかりました({candidates})。fleetest.project 設定で対象を指定するか、プロジェクトを選択してください。",
    en: "fleetest: Multiple test projects were found ({candidates}). Specify the target in the fleetest.project setting, or select a project.",
  },
  "workbench.testTree.selectProjectButton": {
    ja: "プロジェクトを選択",
    en: "Select Project",
  },
  "workbench.testTree.cliLaunchFailedWarning": {
    ja: "fleetest CLI を起動できませんでした({binaryPath})。\"swift build --product fleetest\" でビルド済みか確認してください。",
    en: "Could not launch the fleetest CLI ({binaryPath}). Check whether it has been built with \"swift build --product fleetest\".",
  },
  "workbench.testTree.deletedDescription": {
    ja: "(削除済み)",
    en: "(Deleted)",
  },
  "workbench.testTree.draftDescription": {
    ja: "(作業中)",
    en: "(Draft)",
  },

  "workbench.profileDiag.unresolvedProjectLog": {
    ja: "[fleetest] プロファイル検証: 対象のテストプロジェクトを解決できませんでした。",
    en: "[fleetest] Profile validation: could not resolve the target test project.",
  },
  "workbench.profileDiag.runFailedLog": {
    ja: "[fleetest] プロファイル検証の実行に失敗しました: {error}",
    en: "[fleetest] Profile validation failed to run: {error}",
  },
  "workbench.profileDiag.parseFailedLog": {
    ja: "[fleetest] プロファイル検証の出力を解析できませんでした(exit code: {exitCode})。",
    en: "[fleetest] Could not parse the profile validation output (exit code: {exitCode}).",
  },
  "workbench.profileDiag.validateFailedWarning": {
    ja: "fleetest: プロファイルの検証に失敗しました。対象プロジェクト(fleetest.project)や出力パネル「fleetest」を確認してください。",
    en: "fleetest: Profile validation failed. Check the target project (fleetest.project) setting or the \"fleetest\" output panel.",
  },
  "workbench.profileDiag.validatedInfo": {
    ja: "fleetest: プロファイルを検証しました({total}件中 エラー {errorFiles}件・警告 {warningOnlyFiles}件・問題なし {cleanFiles}件)。",
    en: "fleetest: Validated profiles ({total} total — {errorFiles} error(s), {warningOnlyFiles} warning-only, {cleanFiles} clean).",
  },

  "workbench.orphanSweep.detectFailedLog": {
    ja: "[fleetest] 孤児プロセスの検出に失敗しました(ps): {error}",
    en: "[fleetest] Failed to detect orphan processes (ps): {error}",
  },
  "workbench.orphanSweep.killFailedLog": {
    ja: "[fleetest] 孤児プロセス(PID {pid})の終了に失敗しました: {error}",
    en: "[fleetest] Failed to terminate orphan process (PID {pid}): {error}",
  },
  "workbench.orphanSweep.sweptLog": {
    ja: "[fleetest] 孤児化した常駐プロセスを掃除しました: PID {pids}",
    en: "[fleetest] Cleaned up orphaned resident processes: PID {pids}",
  },

  "workbench.lastResults.cliFailedNoReport": {
    ja: "CLI 実行で失敗(詳細はレポート参照)",
    en: "CLI run failed (see report for details)",
  },
  "workbench.lastResults.cliFailedWithReport": {
    ja: "CLI 実行で失敗 — [レポートを開く](command:fleetest.openScenarioReport?{args})",
    en: "CLI run failed — [Open report](command:fleetest.openScenarioReport?{args})",
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
} satisfies MessageDict;
