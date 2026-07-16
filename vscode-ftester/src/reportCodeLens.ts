// reportCodeLens.ts
// 失敗テストの「レポートを開く」を CodeLens として常設表示する(TestMessage のインライン peek は
// 一度閉じると消えるため、エディタ上に消えない導線を用意する)。対象パターンは watcher.ts の
// WATCH_GLOB と同一(Scenarios 直下・サブフォルダ両方の .swift)。
// refresh() の呼び出し元: lastResultsSync.ts(onResultsApplied)・runHandler.ts(onRunFinished)。

import * as vscode from "vscode";
import { type FtesterConfig, resolveProjectName } from "./config";
import { lastResultsDir, lookupKey, readAllResults, type ResultState } from "./lastResults";
import { WATCH_GLOB } from "./watcher";

/** leaf 1件分の CodeLens 判定に必要な最小情報(vscode.TestItem から抽出、純粋ロジックをテスト可能にするため)。 */
export interface CodeLensLeafInfo {
  id: string;
  uriKey: string;
  line: number;
}

/** documentUriKey に一致し、結果ストアで failed の leaf だけを返す(vscode 非依存)。 */
export function computeFailedLensEntries(
  leaves: readonly CodeLensLeafInfo[],
  documentUriKey: string,
  results: ReadonlyMap<string, ResultState>,
): Array<{ id: string; line: number }> {
  const out: Array<{ id: string; line: number }> = [];
  for (const leaf of leaves) {
    if (leaf.uriKey !== documentUriKey) {
      continue;
    }
    if (results.get(lookupKey(leaf.id)) === "failed") {
      out.push({ id: leaf.id, line: leaf.line });
    }
  }
  return out;
}

function collectLeaves(items: vscode.TestItemCollection, out: CodeLensLeafInfo[]): void {
  items.forEach((item) => {
    if (item.children.size > 0) {
      collectLeaves(item.children, out);
      return;
    }
    if (item.uri && item.range) {
      out.push({ id: item.id, uriKey: item.uri.toString(), line: item.range.start.line });
    }
  });
}

export interface ReportCodeLensDeps {
  controller: vscode.TestController;
  workspaceRoot: string;
  getConfig: () => FtesterConfig;
}

export interface ReportCodeLensController extends vscode.Disposable {
  /** last-results 変化・GUI 実行終了時に外部から再描画を要求する。 */
  refresh(): void;
}

export function registerReportCodeLens(deps: ReportCodeLensDeps): ReportCodeLensController {
  const { controller, workspaceRoot, getConfig } = deps;
  const emitter = new vscode.EventEmitter<void>();

  const provider: vscode.CodeLensProvider = {
    onDidChangeCodeLenses: emitter.event,
    provideCodeLenses(document: vscode.TextDocument): vscode.CodeLens[] {
      const resolution = resolveProjectName(workspaceRoot, getConfig());
      if (resolution.kind !== "resolved") {
        return [];
      }
      const results = readAllResults(lastResultsDir(workspaceRoot, resolution.project));
      if (results.size === 0) {
        return [];
      }
      const leaves: CodeLensLeafInfo[] = [];
      collectLeaves(controller.items, leaves);
      const entries = computeFailedLensEntries(leaves, document.uri.toString(), results);
      return entries.map(
        (entry) =>
          new vscode.CodeLens(new vscode.Range(entry.line, 0, entry.line, 0), {
            title: "❌ 前回失敗 — レポートを開く",
            command: "ftester.openScenarioReport",
            arguments: [entry.id],
          }),
      );
    },
  };

  const selector: vscode.DocumentSelector = {
    language: "swift",
    pattern: new vscode.RelativePattern(workspaceRoot, WATCH_GLOB),
  };
  const registration = vscode.languages.registerCodeLensProvider(selector, provider);

  return {
    refresh(): void {
      emitter.fire();
    },
    dispose(): void {
      registration.dispose();
      emitter.dispose();
    },
  };
}
