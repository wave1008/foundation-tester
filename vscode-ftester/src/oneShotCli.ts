// oneShotCli.ts
// FtesterCli の直列キューに乗せず単発 spawn する CLI 呼び出しヘルパー(list-devices 等、
// ビルドを伴わない読み取り専用コマンド向け)。monitorLiveController.ts/dashboardPanel.ts が共有する。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable } from "node:stream";
import type * as vscode from "vscode";
import { t } from "./i18n";

/** stdin=ignore, stdout/stderr=pipe で spawn したプロセスの型(cli.ts/monitorPanel.ts と同じ形。
 * list-devices のワンショット spawn 専用)。 */
export type PipeProcess = ChildProcessByStdio<null, Readable, Readable>;

export interface OneShotResult {
  readonly json: unknown;
  readonly exitCode: number | null;
  /** 直近数行の stderr(解析失敗時のエラーメッセージ用)。 */
  readonly stderrTail: string;
}

/**
 * `binaryPath` を FtesterCli のキューに乗せず単発 spawn し、stdout 全体を JSON.parse して返す
 * (契約上どの api live/list-devices コマンドも stdout は1行JSONだけなので、NdjsonParser は使わない)。
 */
export function runOneShot(
  binaryPath: string,
  cwd: string,
  args: string[],
  outputChannel: vscode.OutputChannel,
  registerChild: (proc: PipeProcess) => void,
): Promise<OneShotResult> {
  return new Promise((resolve, reject) => {
    let proc: PipeProcess;
    try {
      proc = spawn(binaryPath, args, { cwd, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      reject(new Error(t("run.cli.spawnFailed", { error: String(error) })));
      return;
    }
    registerChild(proc);

    const stdoutChunks: Buffer[] = [];
    const stderrLines: string[] = [];
    proc.stdout.on("data", (chunk: Buffer) => stdoutChunks.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      for (const rawLine of chunk.toString("utf8").split("\n")) {
        const line = rawLine.trim();
        if (line.length > 0) {
          stderrLines.push(line);
          outputChannel.appendLine(`[live stderr] ${line}`);
        }
      }
    });
    proc.on("error", (error) => {
      reject(new Error(t("run.cli.executionError", { message: error.message })));
    });
    proc.on("close", (exitCode) => {
      const text = Buffer.concat(stdoutChunks).toString("utf8").trim();
      let json: unknown;
      if (text.length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          outputChannel.appendLine(t("run.cli.liveParseError", { text }));
        }
      }
      resolve({ json, exitCode, stderrTail: stderrLines.slice(-5).join("\n") });
    });
  });
}
