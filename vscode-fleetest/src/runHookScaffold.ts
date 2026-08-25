// runHookScaffold.ts
// 「スクリプトの雛形を作成する」(プロファイルタブ「リモート制御」)の実体。
// run の前後に走るスクリプトの置き場所と雛形の中身を持つ。
//
// 契約(名前・置き場所・実行規則の正)は Sources/FTCore/RunHooks.swift の RunHookPlan。
// ここはその置き場所へ雛形を書くだけで、判定は一切持たない。雛形の中身(実行規則の説明)は
// i18n/strings/hookScaffold.ts にあり、実行規則を変えたらそちらも一緒に直す。

import * as fs from "node:fs";
import * as path from "node:path";
import { t } from "./i18n";

/** ワークスペース直下のスクリプト置き場(FTCore.RunHookPlan.scriptsDirectoryName と同期)。 */
export const HOOK_SCRIPTS_DIR = "scripts";

/**
 * 実効ワークスペースの絶対パス。**優先順は declared > 既定**
 * (`ProfileResolver.resolveWorkspaceRoot` と同期。`--workspace` 上書きは実行時だけの話なのでここには無い)。
 * declared の相対パスは**リポジトリルート基準**。既定は `<repoRoot>/TestProjects/<project>/workspace`
 * —— この式は webview 側の透かし(runProfilesTab.js)にもあり、3箇所で同じ規則を持つ。
 */
export function resolveWorkspaceDir(repoRoot: string, project: string, declared: string): string {
  const trimmed = declared.trim();
  if (trimmed.length > 0) {
    return path.isAbsolute(trimmed) ? trimmed : path.resolve(repoRoot, trimmed);
  }
  return path.join(repoRoot, "TestProjects", project, "workspace");
}

/**
 * ファイル名 → 中身(FTCore.RunHook.Kind.script と同期)。**関数にする** ——
 * 雛形の中身は locale に追従する(日本語モードならコメントも日本語)ので、module-level の
 * const にすると initI18n 前の既定 locale で固定される(src/i18n/index.ts の契約)。
 */
export function hookScriptTemplates(): ReadonlyMap<string, string> {
  return new Map([
    ["setup.sh", t("hookScaffold.setupTemplate")],
    ["teardown.sh", t("hookScaffold.teardownTemplate")],
  ]);
}

export interface HookScaffoldResult {
  /** scripts/ の絶対パス。 */
  readonly scriptsDir: string;
  /** 実際に作成したファイル名。 */
  readonly created: readonly string[];
  /** 既にあったので触らなかったファイル名。 */
  readonly skipped: readonly string[];
}

/**
 * `<workspace>/scripts/` に雛形を書く。**既にあるファイルは1バイトも触らない**
 * (利用者が書いた片付け手順を雛形で上書きすると、次の run が古い環境を掴んだまま走る)。
 * 実行権(0o755)を付ける —— 付いていなくても実行側が /bin/sh で起動するが、
 * 雛形は shebang を書いてあるので直接実行できる形で置く。
 */
export function writeHookScriptTemplates(workspaceDir: string): HookScaffoldResult {
  const scriptsDir = path.join(workspaceDir, HOOK_SCRIPTS_DIR);
  fs.mkdirSync(scriptsDir, { recursive: true });
  const created: string[] = [];
  const skipped: string[] = [];
  for (const [name, content] of hookScriptTemplates()) {
    const target = path.join(scriptsDir, name);
    if (fs.existsSync(target)) {
      skipped.push(name);
      continue;
    }
    fs.writeFileSync(target, content, { encoding: "utf8", mode: 0o755 });
    created.push(name);
  }
  return { scriptsDir, created, skipped };
}
