// 更新チェック。Scripts/update-check.sh を単発実行し、upstream に未取得のコミットがあれば通知する。
// **取り込みは一切しない**(pull は再ビルド・拡張再インストール・Reload まで伴うので、実行は
// /ftester-update に委ねる)。
//
// 入口は2つあり、**性格が違う**:
//   - checkFtesterUpdate(自動): activate から fire-and-forget(compatCheck.ts と同型)。
//     更新があるときだけ喋る。1日1回・却下済みの版は黙る。
//   - checkFtesterUpdateNow(手動: ftester.checkForUpdate コマンド): 押されたら必ず実行し、
//     **必ず結果を返す**。明示的に押したのに黙るのは誤動作に見えるので、間隔も却下も設定 off も無視する。
//
// 契約: 判定と kv 出力は Scripts/update-check.sh が正。verdict の値を増やしたら両方直す。
//
// 自動側で通知を抑える仕掛けは2つ(どちらも globalState):
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

/** 手動チェックの二重起動ガード(コマンドの連打)。自動チェックは1起動1回なので不要。 */
let manualCheckInFlight = false;

export type UpdateDecision =
  | { readonly kind: "silent"; readonly reason: string }
  | { readonly kind: "notify"; readonly localHead: string; readonly remoteHead: string };

/** 手動チェックの結果。**黙る選択肢が無い**ので、自動側の silent がここでは4通りに割れる。 */
export type ManualOutcome =
  | { readonly kind: "available"; readonly localHead: string; readonly remoteHead: string }
  | { readonly kind: "upToDate" }
  | { readonly kind: "pinned"; readonly reason: string }
  | { readonly kind: "unknown"; readonly reason: string };

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

/** 手動チェックの出力を解釈する。却下済みの版でも通知する(押した本人に隠す理由が無い)。 */
export function decideManualOutcome(fields: Record<string, string>): ManualOutcome {
  const verdict = fields.verdict ?? "";
  const reason = fields.reason ?? "";
  switch (verdict) {
    case "up-to-date":
      return { kind: "upToDate" };
    case "pinned":
      return { kind: "pinned", reason };
    case "update-available": {
      const remoteHead = fields.remote_head ?? "";
      if (remoteHead.length === 0) {
        return { kind: "unknown", reason: "remote_head missing" };
      }
      return { kind: "available", localHead: fields.local_head ?? "", remoteHead };
    }
    default:
      // unknown(reason 付き)と、そもそも verdict 行が無い場合(スクリプトが古い等)。
      return { kind: "unknown", reason: reason || verdict || "no verdict" };
  }
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

  await notifyAvailable(decision, { outputChannel, globalState, dismissedKey });
}

/**
 * ftester.checkForUpdate コマンドの実体。**間隔・却下・設定 off をすべて無視して実行し、
 * 必ず結果を返す**(最新でも「最新です」と答える)。自動チェックの静けさは自動側だけの性質。
 */
export async function checkFtesterUpdateNow(deps: Omit<UpdateCheckDeps, "enabled">): Promise<void> {
  const { workspaceRoot, outputChannel, globalState, registerChild } = deps;
  const toolRoot = resolveToolRoot(workspaceRoot);
  if (!toolRoot) {
    void vscode.window.showWarningMessage(t("update.manual.noToolRoot"));
    return;
  }
  const script = path.join(toolRoot, "Scripts", "update-check.sh");
  if (!fs.existsSync(script)) {
    void vscode.window.showWarningMessage(t("update.manual.noScript"));
    return;
  }

  if (manualCheckInFlight) {
    return; // 連打対策(通知が2枚重なる)。進行中はステータスバーに出ている。
  }
  manualCheckInFlight = true;

  let stdout: string;
  try {
    const running = runScript(script, toolRoot, workspaceRoot, registerChild);
    // ls-remote は1秒前後かかる。押した直後に何も起きないと二度押しされるので進行を出す。
    // **失敗を握った Promise を渡す** ―― 生の Promise が reject すると、拒否を拾わない実装では
    // メッセージが消えないまま unhandled rejection になる
    vscode.window.setStatusBarMessage(t("update.manual.checking"), running.catch(() => undefined));
    stdout = await running;
  } catch (error) {
    void vscode.window.showErrorMessage(
      t("update.check.spawnFailedLog", { error: error instanceof Error ? error.message : String(error) }),
    );
    return;
  } finally {
    manualCheckInFlight = false;
  }
  // 手動で確認した時点で「今チェックした」ので、直後に自動チェックが同じことをしないよう記録する。
  await globalState.update(stateKey(STATE_LAST_CHECKED, toolRoot), Date.now());

  const outcome = decideManualOutcome(parseKeyValues(stdout));
  switch (outcome.kind) {
    case "upToDate":
      void vscode.window.showInformationMessage(t("update.manual.upToDate"));
      return;
    case "pinned":
      void vscode.window.showInformationMessage(t("update.manual.pinned", { reason: outcome.reason }));
      return;
    case "unknown":
      void vscode.window.showWarningMessage(t("update.manual.unknown", { reason: outcome.reason }));
      return;
    case "available":
      await notifyAvailable(
        { kind: "notify", localHead: outcome.localHead, remoteHead: outcome.remoteHead },
        { outputChannel, globalState, dismissedKey: stateKey(STATE_DISMISSED_HEAD, toolRoot) },
      );
  }
}

/** 「更新があります」の通知(自動・手動で同じ見た目)。ボタンの結果まで面倒を見る。 */
async function notifyAvailable(
  decision: Extract<UpdateDecision, { kind: "notify" }>,
  ctx: {
    outputChannel: vscode.OutputChannel;
    globalState: vscode.Memento;
    dismissedKey: string;
  },
): Promise<void> {
  ctx.outputChannel.appendLine(
    t("update.check.availableLog", {
      local: decision.localHead.slice(0, 8),
      remote: decision.remoteHead.slice(0, 8),
    }),
  );
  const open = t("update.notice.openSettingsButton");
  const dismiss = t("update.notice.dismissButton");
  const picked = await vscode.window.showInformationMessage(t("update.notice.message"), open, dismiss);
  if (picked === open) {
    // 更新の実行口は設定タブに1つだけ置く(通知に手順を書くと、実行手段が2箇所に散る)。
    await vscode.commands.executeCommand("ftester.showDeviceMonitor", "settings");
  } else if (picked === dismiss) {
    await ctx.globalState.update(ctx.dismissedKey, decision.remoteHead);
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
