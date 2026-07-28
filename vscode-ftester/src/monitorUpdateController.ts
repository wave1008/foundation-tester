// モニターパネル「設定」タブの更新セクション。判定は Scripts/update-check.sh、取り込みは
// Scripts/update.sh に委譲する(拡張側に更新ロジックを持たない。CLI/スキル/拡張で1実装)。
//
// 契約: webview 側は src/webview/monitor/settingsTab.js。メッセージ型は monitorModel.ts の
// MonitorToWebviewMessage / MonitorFromWebviewMessage と対。片方だけ変えない。
//
// 制約: 更新は**自分自身(拡張)を入れ替える**。完了しても Reload Window までは旧版が動き続ける
// (webview もその時点で作り直される)ので、終了時に必ず再読み込みを促す。

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { t } from "./i18n";
import { parseKeyValues } from "./updateCheck";
import { resolveToolRoot } from "./toolRootResolve";

/** 設定タブに出す更新の状態。`unavailable` はクローンやスクリプトが見つからない場合。 */
export type UpdateState =
  | "unknown"
  | "checking"
  | "up-to-date"
  | "update-available"
  | "pinned"
  | "unavailable"
  | "running";

export interface UpdateStatusMessage {
  readonly type: "updateStatus";
  readonly state: UpdateState;
  /** 短縮 sha(表示用)。取得できないときは空。 */
  readonly localHead: string;
  readonly remoteHead: string;
  /** update-check.sh の reason=(英語。契約はスクリプト冒頭)。 */
  readonly reason: string;
}

export interface MonitorUpdateDeps {
  readonly workspaceRoot: string;
  readonly outputChannel: vscode.OutputChannel;
  post(message: unknown): void;
}

export class MonitorUpdateController {
  private running = false;

  constructor(private readonly deps: MonitorUpdateDeps) {}

  /** パネルを開いたとき/「更新を確認」を押されたときに呼ぶ。 */
  async check(): Promise<void> {
    if (this.running) {
      return; // 更新実行中は状態を上書きしない
    }
    const script = this.scriptPath("update-check.sh");
    if (!script) {
      this.postStatus("unavailable");
      return;
    }
    this.postStatus("checking");
    const result = await this.run("bash", [script, "--tool-root", this.toolRoot()!], false);
    const fields = parseKeyValues(result.stdout);
    const verdict = fields.verdict ?? "";
    const state: UpdateState =
      verdict === "up-to-date" || verdict === "update-available" || verdict === "pinned"
        ? verdict
        : "unknown";
    this.postStatus(state, fields.local_head ?? "", fields.remote_head ?? "", fields.reason ?? "");
  }

  /** 「更新する」を押されたとき。update.sh の出力を1行ずつ webview へ流す。 */
  async runUpdate(): Promise<void> {
    if (this.running) {
      return;
    }
    const script = this.scriptPath("update.sh");
    if (!script) {
      this.postStatus("unavailable");
      return;
    }
    // **確認はここ(ホスト側)で出す**。webview では window.confirm が効かない(VSCode の制約。
    // プロファイル削除など他の破壊的操作も同じ方式)。数分かかるうえ拡張自身を入れ替えるため。
    const proceed = t("monitor.update.confirmButton");
    const choice = await vscode.window.showWarningMessage(
      t("monitor.update.confirmMessage"), { modal: true }, proceed);
    if (choice !== proceed) {
      return;
    }
    this.running = true;
    this.deps.post({ type: "updateLogReset" });
    this.postStatus("running");
    this.deps.post({ type: "updateLog", line: t("monitor.update.startLog") });
    const result = await this.run(
      "bash",
      [script, "--work-dir", this.deps.workspaceRoot, "--tool-root", this.toolRoot()!],
      true,
    );
    this.running = false;
    this.deps.post({ type: "updateFinished", exitCode: result.exitCode ?? -1 });
    // 成否に関わらず状態を取り直す(失敗しても pull だけ通っていることがある)
    await this.check();
  }

  private toolRoot(): string | undefined {
    return resolveToolRoot(this.deps.workspaceRoot);
  }

  private scriptPath(name: string): string | undefined {
    const root = this.toolRoot();
    if (!root) {
      return undefined;
    }
    const script = path.join(root, "Scripts", name);
    return fs.existsSync(script) ? script : undefined;
  }

  private postStatus(state: UpdateState, localHead = "", remoteHead = "", reason = ""): void {
    const message: UpdateStatusMessage = { type: "updateStatus", state, localHead, remoteHead, reason };
    this.deps.post(message);
  }

  /** stream=true なら stdout/stderr を行単位で webview へ流す(update.sh は数分かかる)。 */
  private run(
    command: string,
    args: string[],
    stream: boolean,
  ): Promise<{ stdout: string; exitCode: number | null }> {
    return new Promise((resolve) => {
      let proc;
      try {
        proc = spawn(command, args, {
          cwd: this.deps.workspaceRoot,
          shell: false,
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (error) {
        this.deps.outputChannel.appendLine(
          t("update.check.spawnFailedLog", { error: error instanceof Error ? error.message : String(error) }),
        );
        resolve({ stdout: "", exitCode: -1 });
        return;
      }
      let stdout = "";
      let pending = "";
      const emit = (chunk: Buffer): void => {
        const text = chunk.toString("utf8");
        stdout += text;
        if (!stream) {
          return;
        }
        // 行が分割されて届くので、改行までバッファする(webview 側で1行=1要素にするため)
        pending += text;
        const lines = pending.split("\n");
        pending = lines.pop() ?? "";
        for (const line of lines) {
          this.deps.post({ type: "updateLog", line });
        }
      };
      proc.stdout.on("data", emit);
      proc.stderr.on("data", emit);
      proc.on("error", () => resolve({ stdout, exitCode: -1 }));
      proc.on("close", (exitCode) => {
        if (stream && pending.length > 0) {
          this.deps.post({ type: "updateLog", line: pending });
        }
        resolve({ stdout, exitCode });
      });
    });
  }
}
