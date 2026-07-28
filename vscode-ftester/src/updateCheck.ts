// 起動時の更新チェック。Scripts/update-check.sh を単発実行し、upstream に未取得のコミットが
// あれば通知1本を出す。**取り込みは一切しない**(pull は再ビルド・拡張再インストール・Reload まで
// 伴うので、実行は /ftester-update に委ねる)。compatCheck.ts と同じく activate をブロックしない
// fire-and-forget。
//
// 契約: 判定と kv 出力は Scripts/update-check.sh が正。verdict の値を増やしたら両方直す。
//
// 通知を抑える仕掛けは2つ(どちらも globalState):
//   - 前回チェックから CHECK_INTERVAL_MS 未満なら実行そのものをしない(起動のたびに git を叩かない)
//   - 「この版は通知しない」を押された upstream head は、次の版が出るまで黙る

import * as fs from "node:fs";
import { spawn } from "node:child_process";
import * as path from "node:path";
import * as vscode from "vscode";
import { t } from "./i18n";
import type { PipeProcess } from "./oneShotCli";
import { resolveToolRoot } from "./toolRootResolve";

/** 同一マシンで1日1回まで。起動のたびにネットワークへ出ないための下限。 */
export const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

// globalState はウィンドウ横断で共有される。**キーはクローン単位にする** ―― 別クローンを引く
// 2つのワークスペースを開いていると、片方のチェックがもう片方を24時間黙らせてしまう
const STATE_LAST_CHECKED = "ftester.updateCheck.lastCheckedAt";
const STATE_DISMISSED_HEAD = "ftester.updateCheck.dismissedHead";
const stateKey = (base: string, toolRoot: string): string => `${base}:${toolRoot}`;

/** update-check.sh 側のタイムアウト(20s)より長くしないと、殺す前にこちらが諦めてしまう。 */
const SCRIPT_TIMEOUT_MS = 30_000;

export type UpdateDecision =
  | { readonly kind: "silent"; readonly reason: string }
  | { readonly kind: "notify"; readonly localHead: string; readonly remoteHead: string };

/** `key=value` 行(update-check.sh の出力)を辞書にする。値に = を含む行は最初の = で分ける。 */
export function parseKeyValues(stdout: string): Record<string, string> {
  const fields: Record<string, string> = {};
  for (const line of stdout.split("\n")) {
    const eq = line.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    fields[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return fields;
}

/** 前回チェックからの経過で、今回実行するかを決める。未記録なら実行する。 */
export function isCheckDue(lastCheckedAt: number | undefined, now: number): boolean {
  if (lastCheckedAt === undefined || !Number.isFinite(lastCheckedAt)) {
    return true;
  }
  // 時計が巻き戻った(lastCheckedAt が未来)場合も実行する。放置すると永久に黙るため。
  return now < lastCheckedAt || now - lastCheckedAt >= CHECK_INTERVAL_MS;
}

/** update-check.sh の出力から通知するかを決める。**update-available 以外はすべて黙る**。 */
export function decideUpdateNotice(
  fields: Record<string, string>,
  dismissedHead: string | undefined,
): UpdateDecision {
  const verdict = fields.verdict ?? "";
  if (verdict !== "update-available") {
    return { kind: "silent", reason: `${verdict || "no-verdict"}${fields.reason ? `: ${fields.reason}` : ""}` };
  }
  const remoteHead = fields.remote_head ?? "";
  const localHead = fields.local_head ?? "";
  if (remoteHead.length === 0) {
    return { kind: "silent", reason: "remote_head missing" };
  }
  if (remoteHead === dismissedHead) {
    return { kind: "silent", reason: "dismissed" };
  }
  return { kind: "notify", localHead, remoteHead };
}

export interface UpdateCheckDeps {
  readonly workspaceRoot: string;
  readonly enabled: boolean;
  readonly outputChannel: vscode.OutputChannel;
  readonly globalState: vscode.Memento;
  readonly registerChild: (proc: PipeProcess) => void;
}

/**
 * 更新の有無を確認し、あれば通知する。ネットワーク不通・未クローン・スクリプト不在は
 * 黙ってスキップする(fresh clone やオフラインで毎回警告を出さないため)。
 */
export async function checkFtesterUpdate(deps: UpdateCheckDeps): Promise<void> {
  const { workspaceRoot, enabled, outputChannel, globalState, registerChild } = deps;
  if (!enabled) {
    return;
  }
  const toolRoot = resolveToolRoot(workspaceRoot);
  if (!toolRoot) {
    return;
  }
  const now = Date.now();
  const lastCheckedKey = stateKey(STATE_LAST_CHECKED, toolRoot);
  if (!isCheckDue(globalState.get<number>(lastCheckedKey), now)) {
    return;
  }
  const script = path.join(toolRoot, "Scripts", "update-check.sh");
  if (!fs.existsSync(script)) {
    return; // 更新チェックを持たない古いクローン。
  }

  // 失敗しても記録する(オフラインのたびに毎回 git を起動しない)。
  await globalState.update(lastCheckedKey, now);

  let stdout: string;
  try {
    stdout = await runScript(script, toolRoot, workspaceRoot, registerChild);
  } catch (error) {
    outputChannel.appendLine(
      t("update.check.spawnFailedLog", { error: error instanceof Error ? error.message : String(error) }),
    );
    return;
  }

  const fields = parseKeyValues(stdout);
  const dismissedKey = stateKey(STATE_DISMISSED_HEAD, toolRoot);
  const decision = decideUpdateNotice(fields, globalState.get<string>(dismissedKey));
  if (decision.kind === "silent") {
    outputChannel.appendLine(t("update.check.silentLog", { reason: decision.reason }));
    return;
  }

  outputChannel.appendLine(
    t("update.check.availableLog", {
      local: decision.localHead.slice(0, 8),
      remote: decision.remoteHead.slice(0, 8),
    }),
  );
  const howTo = t("update.notice.howToButton");
  const dismiss = t("update.notice.dismissButton");
  const picked = await vscode.window.showInformationMessage(t("update.notice.message"), howTo, dismiss);
  if (picked === howTo) {
    outputChannel.appendLine(t("update.steps.log", { toolRoot }));
    outputChannel.show(true);
  } else if (picked === dismiss) {
    await globalState.update(dismissedKey, decision.remoteHead);
  }
}

/** bash で update-check.sh を実行し stdout を返す。終了コードは見ない(判定は verdict= 行)。 */
function runScript(
  script: string,
  toolRoot: string,
  cwd: string,
  registerChild: (proc: PipeProcess) => void,
): Promise<string> {
  return new Promise((resolve, reject) => {
    let proc: PipeProcess;
    try {
      proc = spawn("bash", [script, "--tool-root", toolRoot], {
        cwd,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      reject(new Error(String(error)));
      return;
    }
    registerChild(proc);

    const chunks: Buffer[] = [];
    proc.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    proc.stderr.on("data", () => {
      // スクリプトは stderr に判定を出さない(出るのは git の雑音)。捨てる。
    });
    // スクリプト側のタイムアウトが効かなかった場合の保険。放置すると Promise が解決せず
    // registerChild したプロセスが拡張の寿命まで残る
    const timer = setTimeout(() => proc.kill("SIGTERM"), SCRIPT_TIMEOUT_MS);
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", () => {
      clearTimeout(timer);
      resolve(Buffer.concat(chunks).toString("utf8"));
    });
  });
}
