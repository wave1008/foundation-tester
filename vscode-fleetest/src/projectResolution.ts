// projectResolution.ts
// 対象プロジェクトの解決規則(vscode 非依存。config.ts の resolveProjectName が候補を集めてここへ渡す)。
// 同じ規則を CLI/MCP も持つ(Sources/FTCore/TestProject.swift ProjectStore.find)。片方だけ変えない。

/** 拡張が起動時に用意する既定プロジェクト名(`TestProjects/default/`)。
 * Sources/FTCore/TestProject.swift の ProjectStore.defaultProjectName と同じ文字列
 * (defaultProjectNameSync.test.mjs が突き合わせる)。 */
export const DEFAULT_PROJECT_NAME = "default";

export type ProjectResolution =
  | { kind: "resolved"; project: string }
  | { kind: "none" }
  | { kind: "ambiguous"; candidates: string[] };

/**
 * 設定値(fleetest.project)が空でなければそれ。空なら候補が1つならそれ →
 * DEFAULT_PROJECT_NAME が候補に居ればそれ → 0件は none / 複数は ambiguous。
 */
export function resolveProjectFrom(configured: string, candidates: readonly string[]): ProjectResolution {
  const trimmed = configured.trim();
  if (trimmed.length > 0) {
    return { kind: "resolved", project: trimmed };
  }
  if (candidates.length === 1) {
    return { kind: "resolved", project: candidates[0]! };
  }
  if (candidates.length === 0) {
    return { kind: "none" };
  }
  if (candidates.includes(DEFAULT_PROJECT_NAME)) {
    return { kind: "resolved", project: DEFAULT_PROJECT_NAME };
  }
  return { kind: "ambiguous", candidates: [...candidates] };
}
