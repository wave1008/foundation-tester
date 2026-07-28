// foundation-tester クローン(TOOL_ROOT)の解決(vscode 非依存。node --test から直接検証可)。
// clone 構成 = ワークスペース自身。外部パッケージ構成 = Package.swift の .package(path:) が指す先、
// 無ければ既定の隣(../foundation-tester)。
//
// 契約: 解決規則は Scripts/preflight.sh / Scripts/update-check.sh と同じ。片方だけ変えない。

import * as fs from "node:fs";
import * as path from "node:path";

/** クローンであることの判別に使うディレクトリ(受け手のパッケージには存在しない)。 */
const CLONE_MARKER = path.join("Sources", "FTScenarioRunner");

function isCloneRoot(dir: string): boolean {
  try {
    return fs.statSync(path.join(dir, CLONE_MARKER)).isDirectory();
  } catch {
    return false;
  }
}

/** Package.swift の最初の `.package(path: "...")` を返す(宣言が無ければ undefined)。 */
export function declaredPackagePath(packageSwiftSource: string): string | undefined {
  return /\.package\(path:\s*"([^"]*)"/.exec(packageSwiftSource)?.[1];
}

/**
 * workspaceRoot から TOOL_ROOT を解決する。見つからなければ undefined
 * (未導入・別レイアウト。呼び出し側は黙ってスキップする)。
 */
export function resolveToolRoot(workspaceRoot: string): string | undefined {
  if (isCloneRoot(workspaceRoot)) {
    return workspaceRoot;
  }
  const candidates: string[] = [];
  try {
    const declared = declaredPackagePath(fs.readFileSync(path.join(workspaceRoot, "Package.swift"), "utf8"));
    if (declared) {
      candidates.push(declared);
    }
  } catch {
    // Package.swift が無い/読めない。既定の隣だけ見る。
  }
  candidates.push(path.join("..", "foundation-tester"));

  for (const candidate of candidates) {
    const abs = path.isAbsolute(candidate) ? candidate : path.join(workspaceRoot, candidate);
    if (isCloneRoot(abs)) {
      return abs;
    }
  }
  return undefined;
}
