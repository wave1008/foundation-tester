// last-results(シナリオ毎の最終結果)の読み取り。vscode 非依存(テストは vscode-stub が
// 空 Proxy のため、runHandler.ts から import すると module top-level の TestTag 等で落ちる)。
// 書き手は Swift 側 LastResultsStore.swift(1シナリオ=1ファイル、内容 "passed"|"failed")。
//
// **レイアウトは (project, profile) 単位**: `.fleetest/last-results/<project>/`
// の直下はプロファイルごとのサブディレクトリ(profile-less は `_no-profile`。
// `LastResultsStore.noProfileKey` と一致させること)で、その中に `<シナリオID>` ファイルが並ぶ。
// Test Explorer のアイコンはプロファイルを跨いだ1つの合否表示なので、**複数プロファイルの記録は
// 「どれか1つでも failed なら failed」に畳んで1つの状態へ集約する**(別プロファイルの緑が
// 赤を隠す形を UI 側で作らないため)。

import fs from "node:fs";
import path from "node:path";

/** .fleetest/last-results/<project>/ の絶対パス(LastResultsStore.swift stateDir と同一規則。
 * workspaceRoot = Package.swift のあるフォルダ = CLI 実行時の cwd なので packageRoot() と一致する)。
 * 直下はプロファイルごとのサブディレクトリ(readAllResults 参照)。 */
export function lastResultsDir(workspaceRoot: string, project: string): string {
  return path.join(workspaceRoot, ".fleetest", "last-results", project);
}

export type ResultState = "passed" | "failed";

/** last-results ディレクトリ(`<project>/`)を1回読み、直下の**プロファイルごとのサブディレクトリ**
 * を横断してシナリオID(NFC 正規化済み、理由は readFailedScenarioIds 参照)→ 状態の Map を作る。
 * 複数プロファイルに同じシナリオIDの記録があれば、**どれか1つでも "failed" なら "failed"**
 * (別プロファイルの緑で赤を隠さない)。ディレクトリ無し/読み取り不可は空 Map。 */
export function readAllResults(dir: string): Map<string, ResultState> {
  const result = new Map<string, ResultState>();
  let profileDirs: string[];
  try {
    profileDirs = fs.readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  } catch {
    return result;
  }
  for (const profileDir of profileDirs) {
    let names: string[];
    try {
      names = fs.readdirSync(path.join(dir, profileDir));
    } catch {
      continue;
    }
    for (const name of names) {
      try {
        const content = fs.readFileSync(path.join(dir, profileDir, name), "utf8").trim();
        if (content !== "passed" && content !== "failed") {
          continue;
        }
        const key = name.normalize("NFC");
        if (content === "failed" || result.get(key) !== "failed") {
          result.set(key, content);
        }
      } catch {
        // 壊れた/競合中のファイルはスキップ
      }
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
