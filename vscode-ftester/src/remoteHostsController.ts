// remoteHostsController.ts
// リモートホスト登録簿の CLI 越しの読み書き(docs/remote-runner.md §13「原則」)。
// 正は CLI の LocalConfig(~/.config/ftester/config.json)、拡張はここでは保持しない
// (monitorPanel.ts が直近取得分を lastKnownRemoteHosts に控えるのは差分計算のためだけ)。
//
// 契約(CLI 側と並行実装):
//   ftester api remote-hosts                     → {"hosts":[{name,host,dir,machine}, …]}
//   ftester api remote-hosts --import '<JSON配列>' → upsert 後の一覧を同じ形で返す
//   ftester api remote-hosts --remove <name>       → 削除後の一覧を同じ形で返す
// 出力は1行 JSON、失敗は非ゼロ終了(oneShotCli.ts の runOneShot が spawn+JSON.parse を担う)。
//
// spawn を伴う glue(fetchRemoteHosts 等)は他の単発 CLI 呼び出し(compatCheck.ts・
// monitorDeviceOps.ts の device-catalog 等)と同じく直接テストしない。ディスパッチ先の解決
// (resolveRemoteDispatchTarget)だけは fetch を注入引数にして純粋にテストできる形にしてある
// (test/remoteHostsController.test.mjs)。

import type * as vscode from "vscode";
import type { FtesterConfig } from "./config";
import { type PipeProcess, runOneShot } from "./oneShotCli";
import {
  parseRemoteHostsResponse,
  type RemoteHostEntry,
  resolveRemoteTarget,
  type RemoteTargetResolution,
} from "./remoteRunArgs";

export interface RemoteHostsCliDeps {
  readonly workspaceRoot: string;
  readonly outputChannel: vscode.OutputChannel;
  getConfig(): FtesterConfig;
  registerChild(proc: PipeProcess): void;
}

async function runRemoteHostsCli(
  deps: RemoteHostsCliDeps,
  args: readonly string[],
): Promise<RemoteHostEntry[] | undefined> {
  const config = deps.getConfig();
  let result: Awaited<ReturnType<typeof runOneShot>>;
  try {
    result = await runOneShot(config.binaryPath, deps.workspaceRoot, [...args], deps.outputChannel, deps.registerChild);
  } catch (error) {
    deps.outputChannel.appendLine(
      `[remote-hosts] ${args.join(" ")}: ${error instanceof Error ? error.message : String(error)}`,
    );
    return undefined;
  }
  if (result.exitCode !== 0) {
    deps.outputChannel.appendLine(
      `[remote-hosts] ${args.join(" ")} failed (exit ${String(result.exitCode)}): ${result.stderrTail}`,
    );
    return undefined;
  }
  const hosts = parseRemoteHostsResponse(result.json);
  if (hosts === undefined) {
    deps.outputChannel.appendLine(`[remote-hosts] ${args.join(" ")}: unexpected output shape`);
  }
  return hosts;
}

/** `ftester api remote-hosts` で登録簿全体を読む。失敗時は undefined(呼び出し側でログ済み)。 */
export function fetchRemoteHosts(deps: RemoteHostsCliDeps): Promise<RemoteHostEntry[] | undefined> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts"]);
}

/** entries を upsert し、結果の一覧(全件)を返す。空配列を渡しても安全(何もしない)。 */
export function importRemoteHosts(
  deps: RemoteHostsCliDeps,
  entries: readonly RemoteHostEntry[],
): Promise<RemoteHostEntry[] | undefined> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts", "--import", JSON.stringify(entries)]);
}

/** name の登録を削除し、結果の一覧を返す。 */
export function removeRemoteHost(deps: RemoteHostsCliDeps, name: string): Promise<RemoteHostEntry[] | undefined> {
  return runRemoteHostsCli(deps, ["api", "remote-hosts", "--remove", name]);
}

/**
 * ftester.remote.target を解決する(runHandler.ts のディスパッチ判定用)。target が空なら
 * ローカル実行で確定するため fetchHosts は呼ばない(大半の実行はローカルで、毎回
 * remote-hosts を叩くコストを避ける)。非空のときだけ登録簿を引く。
 * fetchHosts を注入引数にすることで、spawn/vscode を経由せず純粋にテストできる。
 * fetchHosts が undefined を返した(CLI 呼び出し失敗)場合は空の登録簿として扱う ——
 * resolveRemoteTarget が「見つからない」= error に倒すので、黙ってローカルへは
 * フォールバックしない(docs/remote-runner.md §12 の契約を維持)。
 */
export async function resolveRemoteDispatchTarget(
  target: string,
  fetchHosts: () => Promise<RemoteHostEntry[] | undefined>,
): Promise<RemoteTargetResolution> {
  if (target.trim().length === 0) {
    return { kind: "local" };
  }
  const hosts = await fetchHosts();
  return resolveRemoteTarget(target, hosts ?? []);
}
