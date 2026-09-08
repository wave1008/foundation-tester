// defaultProject.ts
// 起動時に既定プロジェクト(TestProjects/default/)を用意する(vscode 非依存。文言は呼び手が持つ)。
// 雛形と Package.swift への登録は CLI(`fleetest project create`)に委ねる —— 拡張が JSON や
// _Main.swift を自前で書くと CLI の雛形と二重管理になる。
// 呼び出しは FleetestCli のキューに乗せる(Package.swift を書き換えるので、list-scenarios の
// ビルドと同時に走らせない)。

import * as fs from "node:fs";
import * as path from "node:path";
import type { CliInvocation, CliResult } from "./cli";
import { DEFAULT_PROJECT_NAME } from "./projectResolution";

export type DefaultProjectOutcome =
  | { kind: "present" }
  | { kind: "created" }
  | { kind: "failed"; detail: string };

export interface EnsureDefaultProjectDeps {
  readonly workspaceRoot: string;
  readonly binaryPath: string;
  readonly cli: { invoke(binaryPath: string, cwd: string, invocation: CliInvocation): Promise<CliResult> };
  /** CLI の出力行(stdout/stderr とも)を受ける。出力パネル向け。 */
  readonly log: (line: string) => void;
}

export function defaultProjectDir(workspaceRoot: string): string {
  return path.join(workspaceRoot, "TestProjects", DEFAULT_PROJECT_NAME);
}

/** "present" = ディレクトリがあり中身がある。"missing" = 無い、または空(受け手が mkdir しただけ。
 * CLI 側 ProjectScaffold.canScaffold と同じ判定で、空なら create が通る)。 */
export function defaultProjectState(workspaceRoot: string): "present" | "missing" {
  const dir = defaultProjectDir(workspaceRoot);
  try {
    if (!fs.statSync(dir).isDirectory()) {
      return "present";
    }
    const entries = fs.readdirSync(dir).filter((name) => name !== ".DS_Store");
    return entries.length > 0 ? "present" : "missing";
  } catch {
    return "missing";
  }
}

export async function ensureDefaultProject(deps: EnsureDefaultProjectDeps): Promise<DefaultProjectOutcome> {
  if (defaultProjectState(deps.workspaceRoot) === "present") {
    return { kind: "present" };
  }
  const tail: string[] = [];
  let result: CliResult;
  try {
    result = await deps.cli.invoke(deps.binaryPath, deps.workspaceRoot, {
      args: ["project", "create", DEFAULT_PROJECT_NAME],
      // stdout は人向けの文(JSON ではない)。NDJSON モードにして行ごとに onLog へ流す
      // (既定モードだと JSON.parse 失敗の行が出力パネルに残る)。
      onNdjsonValue: () => undefined,
      onLog: (line) => {
        tail.push(line);
        deps.log(line);
      },
    });
  } catch (error) {
    return { kind: "failed", detail: error instanceof Error ? error.message : String(error) };
  }
  if (result.exitCode !== 0) {
    return { kind: "failed", detail: tail.slice(-3).join(" / ") };
  }
  return { kind: "created" };
}
