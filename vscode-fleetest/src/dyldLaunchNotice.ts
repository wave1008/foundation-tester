// dyldLaunchNotice.ts
// fleetest バイナリの起動失敗(dyld: Symbol not found / Library not loaded = macOS と Xcode の
// 版ずれ)を、子プロセスの stderr から捕まえてセッション中1回だけ通知する。判定・門は
// dyldLaunchFailure.ts(vscode 非依存)。呼び出し元は fleetest 本体を spawn する全経路
// (cli.ts/oneShotCli.ts/monitorProcessManager.ts/monitorDeviceOps.ts/monitorDeviceCreateOps.ts/
// monitorLiveController.ts/monitorPanel.ts/runHandler.ts。debugAdapter.ts は「vscode 非依存」契約が
// あるため直接ここを import せず、検出だけ済ませて debugConfig.ts 経由で notifyDyldLaunchFailureLine を呼ぶ)。
// 既存のエラー表示(失敗の通知・OUTPUT ログ)は変えず、この通知を追加で出すだけ。

import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { DyldNotifyGate, detectDyldLaunchFailure } from "./dyldLaunchFailure";
import { currentLocale, t } from "./i18n";
import { resolveToolRoot } from "./toolRootResolve";

// 拡張プロセスの寿命と同じ1インスタンス。全呼び出し元がこれを共有することで
// 「セッション中1回」を横断的に成立させる。
const gate = new DyldNotifyGate();

/** stderr の断片を dyld 判定に通し、当たれば(セッション初回のみ)通知する。 */
export function checkForDyldLaunchFailure(stderrChunk: string, workspaceRoot: string): void {
  const line = detectDyldLaunchFailure(stderrChunk);
  if (line !== null) {
    notifyDyldLaunchFailureLine(line, workspaceRoot);
  }
}

/** 判定済みの行を直接通知する(debugAdapter.ts のように検出だけ先に済ませている呼び出し元用)。 */
export function notifyDyldLaunchFailureLine(line: string, workspaceRoot: string): void {
  if (!gate.claim()) {
    return;
  }
  void showDyldLaunchFailureNotice(line, workspaceRoot);
}

async function showDyldLaunchFailureNotice(line: string, workspaceRoot: string): Promise<void> {
  const toolRoot = resolveToolRoot(workspaceRoot);
  const clone = toolRoot ?? t("dyld.launchFailure.clonePlaceholder");
  const message = t("dyld.launchFailure.message", { line, clone });
  const maintenanceDoc = toolRoot ? findMaintenanceDoc(toolRoot) : undefined;
  const detailsLabel = t("dyld.launchFailure.detailsButton");
  const picked = maintenanceDoc
    ? await vscode.window.showErrorMessage(message, detailsLabel)
    : await vscode.window.showErrorMessage(message);
  if (picked === detailsLabel && maintenanceDoc) {
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(maintenanceDoc));
    await vscode.window.showTextDocument(doc);
  }
}

function findMaintenanceDoc(toolRoot: string): string | undefined {
  const name = currentLocale() === "ja" ? "maintenance_ja.md" : "maintenance.md";
  const abs = path.join(toolRoot, "docs", "user-docs", "in_action", name);
  return fs.existsSync(abs) ? abs : undefined;
}
