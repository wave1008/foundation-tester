// scenarioReports.ts
// シナリオ実行レポート(Markdown、CLI が書く)の探索。vscode 非依存(lastResults.ts と同じ理由)。
// ファイル名規則は Swift 側のレポート書き出しコードとの契約:
//   scenario-<YYYYMMDD>-<HHMMSS>-<mmm>-<シナリオID の "." を "_" に置換したもの>.md
// タイムスタンプ部は辞書順 = 時刻順なので、「最新」はファイル名の文字列最大値で求まる。

import fs from "node:fs";
import path from "node:path";

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function reportFileNameRegex(scenarioId: string): RegExp {
  const expectedSuffix = scenarioId.replace(/\./g, "_");
  return new RegExp(`^scenario-\\d{8}-\\d{6}-\\d{3}-${escapeRegExp(expectedSuffix)}\\.md$`);
}

export function reportsDir(workspaceRoot: string, project: string): string {
  return path.join(workspaceRoot, "Projects", project, "reports");
}

/** dir 内で scenarioId に一致する最新レポートの絶対パス。ディレクトリ無し/読み取り不可/該当無しは undefined。
 * readdirSync は macOS だと日本語ファイル名を NFD で返すことがある(lastResults.ts lookupKey と同じ罠)ので
 * 照合前に NFC 正規化する。 */
export function findLatestReport(dir: string, scenarioId: string): string | undefined {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return undefined;
  }
  const regex = reportFileNameRegex(scenarioId);
  let latest: string | undefined;
  for (const name of names) {
    const normalized = name.normalize("NFC");
    if (regex.test(normalized) && (latest === undefined || normalized > latest)) {
      latest = normalized;
    }
  }
  return latest === undefined ? undefined : path.join(dir, latest);
}

export interface RecentReport {
  scenarioId: string;
  path: string;
  fileName: string;
}

/** scenarioIds 各々の最新レポートを、ファイル名(=タイムスタンプ)降順で返す(見つからないものは除外)。 */
export function listRecentReports(dir: string, scenarioIds: Set<string>): RecentReport[] {
  const result: RecentReport[] = [];
  for (const scenarioId of scenarioIds) {
    const reportPath = findLatestReport(dir, scenarioId);
    if (reportPath) {
      result.push({ scenarioId, path: reportPath, fileName: path.basename(reportPath) });
    }
  }
  return result.sort((a, b) => (a.fileName < b.fileName ? 1 : a.fileName > b.fileName ? -1 : 0));
}
