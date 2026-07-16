// last-results(シナリオ毎の最終結果)の読み取り。vscode 非依存(テストは vscode-stub が
// 空 Proxy のため、runHandler.ts から import すると module top-level の TestTag 等で落ちる)。
// 書き手は Swift 側 LastResultsStore.swift(1シナリオ=1ファイル、内容 "passed"|"failed")。

import fs from "node:fs";
import path from "node:path";

/** .ftester/last-results/<project>/ の絶対パス(LastResultsStore.swift stateDir と同一規則。
 * workspaceRoot = Package.swift のあるフォルダ = CLI 実行時の cwd なので packageRoot() と一致する)。 */
export function lastResultsDir(workspaceRoot: string, project: string): string {
  return path.join(workspaceRoot, ".ftester", "last-results", project);
}

export type ResultState = "passed" | "failed";

/** last-results ディレクトリを1回読み、ファイル名(NFC 正規化済み、理由は readFailedScenarioIds 参照)
 * → 内容(passed/failed)の Map を返す。内容がそのどちらでもないファイルは無視する。
 * ディレクトリ無し/読み取り不可は空 Map。 */
export function readAllResults(dir: string): Map<string, ResultState> {
  const result = new Map<string, ResultState>();
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return result;
  }
  for (const name of names) {
    try {
      const content = fs.readFileSync(path.join(dir, name), "utf8").trim();
      if (content === "passed" || content === "failed") {
        result.set(name.normalize("NFC"), content);
      }
    } catch {
      // 壊れた/競合中のファイルはスキップ
    }
  }
  return result;
}

/** last-results ディレクトリを1回読み、内容が "failed" のファイル名(=シナリオID)集合を返す。
 * ディレクトリ無し/読み取り不可は空集合(LastResultsStore.failedIDs と同じ方針)。
 * 集合は NFC 正規化済み — macOS の readdir は日本語名を NFD で返すことがあり、
 * TestItem id(NFC)との JS 完全一致比較が全滅する(Swift の == は正準等価なので CLI は無関係)。
 * 照合側も lookupKey() を通すこと。 */
export function readFailedScenarioIds(dir: string): Set<string> {
  const result = new Set<string>();
  for (const [id, state] of readAllResults(dir)) {
    if (state === "failed") {
      result.add(id);
    }
  }
  return result;
}

/** readFailedScenarioIds の集合を引くためのキー正規化(NFC)。 */
export function lookupKey(scenarioId: string): string {
  return scenarioId.normalize("NFC");
}
