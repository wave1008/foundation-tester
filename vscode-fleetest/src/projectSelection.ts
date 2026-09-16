// projectSelection.ts
// webview のプロジェクト選択(ダッシュボード・録画タブ)から設定 fleetest.project を書き換える。
// 画面の取り直しは呼び手がせず、monitorPanel.ts の onDidChangeConfiguration 購読が行う
// (2経路から refresh すると二重に走る)。

import * as vscode from "vscode";
import { type FleetestConfig, listProjectCandidates, resolveProjectName } from "./config";

export async function selectWorkspaceProject(
  workspaceRoot: string, config: FleetestConfig, project: string,
): Promise<void> {
  if (!listProjectCandidates(workspaceRoot).includes(project)) {
    return;
  }
  const resolution = resolveProjectName(workspaceRoot, config);
  if (resolution.kind === "resolved" && resolution.project === project) {
    return;
  }
  await vscode.workspace
    .getConfiguration("fleetest")
    .update("project", project, vscode.ConfigurationTarget.Workspace);
}
