// モニターパネル「設定」タブの更新セクション。判定は Scripts/update-check.sh、取り込みは
// Scripts/update.sh に委譲する(拡張側に更新ロジックを持たない。CLI/スキル/拡張で1実装)。
//
// 契約: webview 側は src/webview/monitor/settingsTab.js。メッセージ型は monitorModel.ts の
// MonitorToWebviewMessage / MonitorFromWebviewMessage と対。片方だけ変えない。
//
// 制約: 更新は**自分自身(拡張)を入れ替える**。完了しても Reload Window までは旧版が動き続ける
// (webview もその時点で作り直される)ので、終了時に必ず再読み込みを促す。
//
// ログの出し先は **VSCode の OUTPUT(ftester チャンネル)**。webview に持たせない ——
// 検索・コピー・スクロールが VSCode 標準のまま使え、パネルを閉じても残るため。

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

  /** 「更新する」を押されたとき。update.sh を実行し、出力は OUTPUT(ftester)へ1行ずつ出す。 */
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
    this.postStatus("running");
    // 実行のたびに OUTPUT を前面に出す(押した結果がどこに出るのかを迷わせない)。
    this.deps.outputChannel.show(true);
    this.deps.outputChannel.appendLine(t("monitor.update.startLog"));
    // パネルを見ていなくても進行が分かるよう、VSCode 側の進捗通知も出す(数分かかるため)。
    // 中断は用意しない —— 途中で殺すと pull 済み・ビルド未了の半端な状態が残る
    const result = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: t("monitor.update.progressTitle"), cancellable: false },
      (progress) =>
        this.run("bash", [script, "--work-dir", this.deps.workspaceRoot, "--tool-root", this.toolRoot()!], true,
          // 見出し行(`==> …`)だけを進捗の説明に出す。全行だと読めない速さで流れる
          (line) => {
            if (line.startsWith("==>")) {
              progress.report({ message: line.slice(3).trim() });
            }
          }),
    );
    this.running = false;
    const exitCode = result.exitCode ?? -1;
    // 成否に関わらず状態を取り直す(失敗しても pull だけ通っていることがある)
    await this.check();
    if (exitCode === 0) {
      this.deps.outputChannel.appendLine(t("monitor.update.finishedOkLog"));
      // **入れ替えた拡張は再読み込みまで有効にならない**ので、その場で再読み込みを促す。
      // トースト通知だと見落として旧版のまま使い続けるため、**モーダルで出す**
      // (更新を実行した直後という文脈があり、割り込みが正当な唯一の場面)。
      const reload = t("monitor.update.reloadButton");
      const picked = await vscode.window.showInformationMessage(
        t("monitor.update.finishedOk"), { modal: true, detail: t("monitor.update.finishedOkDetail") }, reload);
      if (picked === reload) {
        await vscode.commands.executeCommand("workbench.action.reloadWindow");
      }
    } else {
      this.deps.outputChannel.appendLine(t("monitor.update.finishedFailedLog", { code: String(exitCode) }));
      void vscode.window.showErrorMessage(t("monitor.update.finishedFailed", { code: String(exitCode) }));
    }
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
    onLine?: (line: string) => void,
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
          this.deps.outputChannel.appendLine(line);
          onLine?.(line);
        }
      };
      proc.stdout.on("data", emit);
      proc.stderr.on("data", emit);
      proc.on("error", () => resolve({ stdout, exitCode: -1 }));
      proc.on("close", (exitCode) => {
        if (stream && pending.length > 0) {
          this.deps.outputChannel.appendLine(pending);
        }
        resolve({ stdout, exitCode });
      });
    });
  }
}
