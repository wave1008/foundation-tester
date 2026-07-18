// orphanSweep.ts
// 拡張の activate 時、孤児化した ftester 常駐プロセス(reload window 等で拡張ホストが即死し、
// launchd に reparent されて PPID=1 になったもの)を掃除する。vscode を import しない
// (test/orphanSweep.test.mjs から素の node:test で検証するため)。

import { execFile } from "node:child_process";
import { t } from "./i18n";

const ORPHAN_PPID = 1;

// `ftester api <live serve|host-metrics|monitor|run>` を、パスの前置(相対/絶対)を問わず
// サブコマンド位置で判定する。`api run` は非常駐だが、孤児化するとプロファイル全デバイスの
// ブリッジを占有し続け(親死亡で結果も届かない)、新セッションのモニター表示・実行を阻害する
// ため対象に含める。`api explore` 等その他の非常駐コマンドや、引数中に "monitor" 等の語が
// 偶然出るだけの無関係コマンドは対象外。
const ORPHAN_COMMAND_RE = /(^|\/)ftester(?:\s|$).*\bapi\s+(?:live\s+serve|host-metrics|monitor|run)(?:\s|$)/;

/** ps 出力(`ps -axo pid=,ppid=,command=`)から、孤児化した ftester 常駐プロセスの PID を抽出する。
 * 対象: PPID が 1(親死亡で launchd に reparent 済み=誰の管理下にも無い)かつ、コマンドが
 * ftester の常駐 api サブコマンド(live serve / host-metrics / monitor)であるもの。
 * PPID=1 以外(生きている拡張ホストの子)は絶対に対象にしない(複数ウィンドウ環境の安全条件)。 */
export function parseOrphanPids(psOutput: string): number[] {
  const pids: number[] = [];
  for (const line of psOutput.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    const match = trimmed.match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!match) {
      continue;
    }
    const pid = Number(match[1]);
    const ppid = Number(match[2]);
    const command = match[3] ?? "";
    if (ppid !== ORPHAN_PPID) {
      continue;
    }
    if (!ORPHAN_COMMAND_RE.test(command)) {
      continue;
    }
    pids.push(pid);
  }
  return pids;
}

/** ps 実行→抽出→SIGKILL。エラーは握って log に1行(掃除は best-effort、activate を失敗させない)。
 * 掃除した PID があれば log に報告する。 */
export async function sweepOrphans(log: (message: string) => void): Promise<void> {
  let psOutput: string;
  try {
    psOutput = await new Promise<string>((resolve, reject) => {
      execFile("ps", ["-axo", "pid=,ppid=,command="], (error, stdout) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(stdout);
      });
    });
  } catch (error) {
    log(t("workbench.orphanSweep.detectFailedLog", { error: String(error) }));
    return;
  }

  const pids = parseOrphanPids(psOutput).filter((pid) => pid !== process.pid);
  if (pids.length === 0) {
    return;
  }

  const killed: number[] = [];
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGKILL");
      killed.push(pid);
    } catch (error) {
      // ESRCH(既に終了済み)を含め、個別の失敗で全体を止めない。
      if ((error as NodeJS.ErrnoException)?.code !== "ESRCH") {
        log(t("workbench.orphanSweep.killFailedLog", { pid, error: String(error) }));
      }
    }
  }
  if (killed.length > 0) {
    log(t("workbench.orphanSweep.sweptLog", { pids: killed.join(", ") }));
  }
}
