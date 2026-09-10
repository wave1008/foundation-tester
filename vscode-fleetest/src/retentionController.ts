// retentionController.ts
// クリーンアップ設定(保持ポリシー)と掃除の CLI 越しの読み書き。正は CLI 側のマシン設定で、
// 拡張は値を保持しない(remoteHostsController.ts と同じ原則)。
//
// 契約(CLI 側と並行実装。解釈は retentionModel.ts):
//   fleetest api retention                    → {"policy":{…},"defaults":{…},"usage":{…}}
//   fleetest api retention --import '<JSON>'  → 同じ形(渡した鍵だけ上書き・null で既定へ戻す)
//   fleetest api clean [--dry-run]            → 1行 JSON(合計バイト数とエラー文字列だけ読む)
// 出力は1行 JSON、失敗は非ゼロ終了(oneShotCli.ts の runOneShot が spawn+JSON.parse を担う)。
//
// **コマンドを持たない古い CLI でも壊れない**: 非ゼロ終了・解釈できない出力はどちらも error に
// 畳んで返し、呼び出し側(monitorPanel.ts)がセクションを無効表示にする。

import type * as vscode from "vscode";
import type { FleetestConfig } from "./config";
import { type PipeProcess, runOneShot } from "./oneShotCli";
import {
  type CleanResult,
  parseCleanResult,
  parseRetentionResponse,
  type RetentionPatch,
  type RetentionUsage,
  type RetentionValues,
} from "./retentionModel";

export interface RetentionCliDeps {
  readonly workspaceRoot: string;
  readonly outputChannel: vscode.OutputChannel;
  getConfig(): FleetestConfig;
  registerChild(proc: PipeProcess): void;
}

/** 呼び出し1回の結果。成功時は policy/defaults/usage、失敗時は error(設定タブへそのまま出す)。 */
export interface RetentionCliOutcome {
  readonly policy?: RetentionValues;
  readonly defaults?: RetentionValues;
  readonly usage?: RetentionUsage;
  readonly error?: string;
}

async function runCli(
  deps: RetentionCliDeps,
  args: readonly string[],
  tag: string,
): Promise<{ json?: unknown; error?: string }> {
  const config = deps.getConfig();
  let result: Awaited<ReturnType<typeof runOneShot>>;
  try {
    result = await runOneShot(config.binaryPath, deps.workspaceRoot, [...args], deps.outputChannel, deps.registerChild);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    deps.outputChannel.appendLine(`[${tag}] ${args.join(" ")}: ${message}`);
    return { error: message };
  }
  if (result.exitCode !== 0) {
    deps.outputChannel.appendLine(
      `[${tag}] ${args.join(" ")} failed (exit ${String(result.exitCode)}): ${result.stderrTail}`,
    );
    const message = result.stderrTail.trim();
    return { error: message.length > 0 ? message : `exit ${String(result.exitCode)}` };
  }
  return { json: result.json };
}

function toOutcome(
  deps: RetentionCliDeps,
  args: readonly string[],
  raw: { json?: unknown; error?: string },
): RetentionCliOutcome {
  if (raw.error !== undefined) {
    return { error: raw.error };
  }
  const parsed = parseRetentionResponse(raw.json);
  if (parsed === undefined) {
    deps.outputChannel.appendLine(`[retention] ${args.join(" ")}: unexpected output shape`);
    return { error: "unexpected output shape" };
  }
  return parsed;
}

/** 現在の実効値と既定を読む。**使用量は含まない** —— 集計は全ファイルを stat して回るので
 * 実測 21 秒かかり、待たせると設定タブが空欄のままになる。使用量は `fetchRetentionUsage` で
 * 後から埋める。 */
export async function fetchRetention(deps: RetentionCliDeps): Promise<RetentionCliOutcome> {
  const args = ["api", "retention"];
  return toOutcome(deps, args, await runCli(deps, args, "retention"));
}

/** 使用量まで含めて読み直す(遅い)。上限の表示が出た後に呼ぶ。 */
export async function fetchRetentionUsage(deps: RetentionCliDeps): Promise<RetentionCliOutcome> {
  const args = ["api", "retention", "--usage"];
  return toOutcome(deps, args, await runCli(deps, args, "retention"));
}

/** patch の鍵だけ上書きし、CLI が返した確定形を返す(null は既定へ戻す)。 */
export async function updateRetention(deps: RetentionCliDeps, patch: RetentionPatch): Promise<RetentionCliOutcome> {
  const args = ["api", "retention", "--import", JSON.stringify(patch)];
  return toOutcome(deps, args, await runCli(deps, args, "retention"));
}

/** 掃除の実行(dryRun なら消さずに見積もるだけ)。読むのは合計バイト数とエラー文字列だけ。 */
export async function runCleanup(deps: RetentionCliDeps, dryRun: boolean): Promise<CleanResult> {
  const args = dryRun ? ["api", "clean", "--dry-run"] : ["api", "clean"];
  const raw = await runCli(deps, args, "clean");
  if (raw.error !== undefined) {
    return { error: raw.error };
  }
  return parseCleanResult(raw.json);
}
