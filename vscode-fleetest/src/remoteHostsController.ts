// remoteHostsController.ts
// リモートホスト登録簿の CLI 越しの読み書き(docs/remote-runner.md §13「原則」)。
// 正は CLI の LocalConfig(~/.config/fleetest/config.json)、拡張はここでは保持しない
// (monitorPanel.ts が直近取得分を lastKnownRemoteHosts に控えるのは差分計算のためだけ)。
//
// 契約(CLI 側と並行実装):
//   fleetest api remote-hosts                     → {"hosts":[{name,host,dir,machine}, …]}
//   fleetest api remote-hosts --import '<JSON配列>' → upsert 後の一覧を同じ形で返す
//   fleetest api remote-hosts --remove <name>       → 削除後の一覧を同じ形で返す
// 出力は1行 JSON、失敗は非ゼロ終了(oneShotCli.ts の runOneShot が spawn+JSON.parse を担う)。
//
// spawn を伴う glue(fetchRemoteHosts 等)は他の単発 CLI 呼び出し(compatCheck.ts・
// monitorDeviceOps.ts の device-catalog 等)と同じく直接テストしない。

import type * as vscode from "vscode";
import type { FleetestConfig } from "./config";
import { type PipeProcess, runOneShot } from "./oneShotCli";
import { parseRemoteHostsResponse, type RemoteHostEntry } from "./remoteRunArgs";

export interface RemoteHostsCliDeps {
  readonly workspaceRoot: string;
  readonly outputChannel: vscode.OutputChannel;
  getConfig(): FleetestConfig;
  registerChild(proc: PipeProcess): void;
}

/** 呼び出し1回の結果。成功時は hosts、失敗時は error(理由テキスト。設定タブへそのまま出す)。
 * 両方 undefined にはならない(どちらか一方だけが立つ)。 */
export interface RemoteHostsCliOutcome {
  readonly hosts?: RemoteHostEntry[];
  readonly error?: string;
}

async function runRemoteHostsCli(deps: RemoteHostsCliDeps, args: readonly string[]): Promise<RemoteHostsCliOutcome> {
  const config = deps.getConfig();
  let result: Awaited<ReturnType<typeof runOneShot>>;
  try {
    result = await runOneShot(config.binaryPath, deps.workspaceRoot, [...args], deps.outputChannel, deps.registerChild);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    deps.outputChannel.appendLine(`[remote-hosts] ${args.join(" ")}: ${message}`);
    return { error: message };
  }
  if (result.exitCode !== 0) {
    deps.outputChannel.appendLine(
      `[remote-hosts] ${args.join(" ")} failed (exit ${String(result.exitCode)}): ${result.stderrTail}`,
    );
    const message = result.stderrTail.trim();
    return { error: message.length > 0 ? message : `exit ${String(result.exitCode)}` };
  }
  const hosts = parseRemoteHostsResponse(result.json);
  if (hosts === undefined) {
    deps.outputChannel.appendLine(`[remote-hosts] ${args.join(" ")}: unexpected output shape`);
    return { error: "unexpected output shape" };
  }
  return { hosts };
}

/** `fleetest api remote-hosts` で登録簿全体を読む。失敗時は error(呼び出し側でログ済み)。 */
export function fetchRemoteHosts(deps: RemoteHostsCliDeps): Promise<RemoteHostsCliOutcome> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts"]);
}

/** entries を upsert し、結果の一覧(全件)を返す。空配列を渡しても安全(何もしない)。 */
export function importRemoteHosts(
  deps: RemoteHostsCliDeps,
  entries: readonly RemoteHostEntry[],
): Promise<RemoteHostsCliOutcome> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts", "--import", JSON.stringify(entries)]);
}

/** name の登録を削除し、結果の一覧を返す。 */
export function removeRemoteHost(deps: RemoteHostsCliDeps, name: string): Promise<RemoteHostsCliOutcome> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts", "--remove", name]);
}
