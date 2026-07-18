// cli.ts
// ftester CLI (`ftester api ...`) の spawn・NDJSON/JSON パース・実行キューを担当する。
//
// - spawn は必ず引数配列(シェル非経由)で行い、cwd はワークスペースルートを渡す。
// - 全呼び出しは単一の直列キューで実行する(SPM のビルドロック対策。CLI プロセスを
//   同時に2つ以上走らせない)。
// - key を指定した呼び出しは「未着手の pending は1件だけ」に畳む。連打(例: ファイル監視の
//   立て続けの refresh 要求)で同じ種類のリクエストがキューに複数積まれるのを防ぐ。
//   実行中のタスクはキャンセルしない(次の要求は実行中タスクの後に1件だけ積まれる)。
// - キャンセルは SIGTERM を送り、2秒後もプロセスが残っていれば SIGKILL する。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import type * as vscode from "vscode";
import { t } from "./i18n";
import { NdjsonParser } from "./ndjson";

/**
 * stdout/stderr=pipe で spawn したプロセスの型。stdin は invocation.stdin の有無で
 * "pipe"(Writable)/"ignore"(null)のどちらにもなりうるため union で受ける
 * (readonly プロパティなので、より狭い型で spawn した戻り値もそのまま代入できる)。
 */
type FtesterProcess = ChildProcessByStdio<Writable | null, Readable, Readable>;

export interface CliInvocation {
  /** "api" 以降を含む CLI 引数配列(例: ["api", "list-scenarios", "--project", "P"])。 */
  args: string[];
  /**
   * 指定すると、プロセス起動直後にこの文字列を stdin へ書き込んでから閉じる(EOF)。
   * 省略時は stdin を使わない(stdio: "ignore")。`ftester api apply-heal` 等、
   * stdin から JSON を受け取る CLI 呼び出し用。
   */
  stdin?: string;
  /**
   * 指定すると stdout を NDJSON として1行ずつパースし、JSON化できた値をここに渡す。
   * 省略時は stdout 全体をまとめて JSON.parse し、CliResult.json として返す。
   */
  onNdjsonValue?: (value: unknown) => void;
  /** JSON化できなかった行(NDJSON使用時)や stderr の行を受け取る。診断ログ用。 */
  onLog?: (line: string, stream: "stdout" | "stderr") => void;
}

export interface CliResult {
  /** onNdjsonValue を指定しなかった場合の、stdout 全体を JSON.parse した結果。 */
  json: unknown;
  exitCode: number | null;
  /** SIGTERM/SIGKILL によって終了させられた場合に true。 */
  cancelled: boolean;
}

/** CLI 起動・実行時の実エラー(バイナリ不在・spawn失敗など)。 */
export class CliError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "CliError";
  }
}

/** 同じ key の新しい要求に置き換えられて破棄されたことを表す(呼び出し側はエラー表示不要)。 */
export class CliSupersededError extends Error {
  constructor() {
    super(t("run.cli.superseded"));
    this.name = "CliSupersededError";
  }
}

interface QueuedTask {
  key: string | undefined;
  run: () => Promise<CliResult>;
  resolve: (result: CliResult) => void;
  reject: (error: unknown) => void;
}

export class FtesterCli {
  private readonly queue: QueuedTask[] = [];
  private draining = false;
  private currentProcess: FtesterProcess | undefined;

  constructor(private readonly outputChannel: vscode.OutputChannel) {}

  /**
   * 実行中の CLI プロセスがあれば SIGTERM を送り、2秒後もまだ生きていれば SIGKILL する。
   * 実行中のプロセスが無ければ何もしない。
   */
  cancelCurrent(): void {
    const proc = this.currentProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /**
   * CLI を実行キューに積む。key を指定すると、同じ key を持つ未着手のキュー要求を
   * この呼び出しで置き換える(古い方は CliSupersededError で reject される)。
   */
  invoke(binaryPath: string, cwd: string, invocation: CliInvocation, key?: string): Promise<CliResult> {
    return new Promise<CliResult>((resolve, reject) => {
      if (key !== undefined) {
        const existingIndex = this.queue.findIndex((task) => task.key === key);
        if (existingIndex !== -1) {
          const [removed] = this.queue.splice(existingIndex, 1);
          removed!.reject(new CliSupersededError());
        }
      }
      this.queue.push({
        key,
        run: () => this.execute(binaryPath, cwd, invocation),
        resolve,
        reject,
      });
      void this.drain();
    });
  }

  private async drain(): Promise<void> {
    if (this.draining) {
      return;
    }
    this.draining = true;
    try {
      let task = this.queue.shift();
      while (task) {
        try {
          const result = await task.run();
          task.resolve(result);
        } catch (error) {
          task.reject(error);
        }
        task = this.queue.shift();
      }
    } finally {
      this.draining = false;
    }
  }

  private execute(binaryPath: string, cwd: string, invocation: CliInvocation): Promise<CliResult> {
    return new Promise<CliResult>((resolve, reject) => {
      let proc: FtesterProcess;
      try {
        // stdio[0] は stdin を使うかどうかで literal tuple を分ける("pipe"/"ignore" の
        // union にすると spawn の戻り値型が ChildProcess に緩んでしまうため)。
        proc =
          invocation.stdin !== undefined
            ? spawn(binaryPath, invocation.args, { cwd, shell: false, stdio: ["pipe", "pipe", "pipe"] })
            : spawn(binaryPath, invocation.args, { cwd, shell: false, stdio: ["ignore", "pipe", "pipe"] });
      } catch (error) {
        reject(new CliError(t("run.cli.spawnFailed", { error: String(error) }), error));
        return;
      }
      this.currentProcess = proc;
      if (invocation.stdin !== undefined) {
        proc.stdin?.end(invocation.stdin, "utf8");
      }

      const parseNdjson = invocation.onNdjsonValue !== undefined;
      const stdoutChunks: Buffer[] = [];
      const stdoutParser = new NdjsonParser(
        (value) => invocation.onNdjsonValue?.(value),
        (line) => invocation.onLog?.(line, "stdout"),
      );
      const stderrParser = new NdjsonParser(
        (value) => invocation.onLog?.(JSON.stringify(value), "stderr"),
        (line) => invocation.onLog?.(line, "stderr"),
      );

      proc.stdout.on("data", (chunk: Buffer) => {
        if (parseNdjson) {
          stdoutParser.push(chunk);
        } else {
          stdoutChunks.push(chunk);
        }
      });
      proc.stderr.on("data", (chunk: Buffer) => {
        stderrParser.push(chunk);
      });

      proc.on("error", (error) => {
        this.currentProcess = undefined;
        reject(new CliError(t("run.cli.executionError", { message: error.message }), error));
      });

      proc.on("close", (exitCode, signal) => {
        this.currentProcess = undefined;
        if (parseNdjson) {
          stdoutParser.end();
        }
        stderrParser.end();

        const cancelled = signal === "SIGTERM" || signal === "SIGKILL";
        let json: unknown;
        if (!parseNdjson) {
          const text = Buffer.concat(stdoutChunks).toString("utf8").trim();
          if (text.length > 0) {
            try {
              json = JSON.parse(text);
            } catch {
              this.outputChannel.appendLine(t("run.cli.parseError", { text }));
            }
          }
        }
        resolve({ json, exitCode, cancelled });
      });
    });
  }
}
