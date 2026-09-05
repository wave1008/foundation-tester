// orphanSweep.ts
// 拡張の activate 時、孤児化した fleetest 常駐プロセス(reload window 等で拡張ホストが即死し、
// launchd に reparent されて PPID=1 になったもの)を掃除する。vscode を import しない
// (test/orphanSweep.test.mjs から素の node:test で検証するため)。

import { execFile } from "node:child_process";
import { childEnv } from "./childEnv";
import { t } from "./i18n";

const ORPHAN_PPID = 1;

// `fleetest api <live serve|host-metrics|monitor|run|device-stream>` を、パスの前置(相対/絶対)を
// 問わずサブコマンド位置で判定する(`remote exec <machine> -- api device-stream …` もこの形で
// 拾える — "api" の前に任意の前置句が入るだけ)。`api run` は非常駐だが、孤児化するとプロファイル
// 全デバイスのブリッジを占有し続け(親死亡で結果も届かない)、新セッションのモニター表示・実行を
// 阻害するため対象に含める。`api gen-scenario` 等その他の非常駐コマンドや、引数中に "monitor" 等の
// 語が偶然出るだけの無関係コマンドは対象外。
//
// 配信ヘルパー(fleetest-simstream / fleetest-androidstream / fleetest-devicepoll)も別枝で拾う ——
// stdin EOF で自ら終わる設計だが、拡張ホストが瞬断されて EOF が届かない形では launchd に
// reparent されて残る(実害 2026-09-01: 孤児の配信が VSCode 再起動でも死なず、リモート Android の
// E2E を接続断で赤にした。Android の孤児 screenrecord は実際に E2E を落とす)。
// "fleetest" の直後が "-" なので上のサブコマンド判定(`fleetest(?:\s|$)`)には一致せず、専用の
// 枝が要る(residentProcesses.ts の stream 判定と同じ理由)。
const ORPHAN_COMMAND_RE =
  /(^|\/)fleetest(?:\s|$).*\bapi\s+(?:live\s+serve|host-metrics|monitor|run|device-stream)(?:\s|$)|(^|\/)fleetest-(?:simstream|androidstream|devicepoll)(?:\s|$)/;

/** ps 出力(`ps -axo pid=,ppid=,command=`)から、孤児化した fleetest 常駐プロセスの PID を抽出する。
 * 対象: PPID が 1(親死亡で launchd に reparent 済み=誰の管理下にも無い)かつ、コマンドが
 * fleetest の常駐 api サブコマンド(live serve / host-metrics / monitor / run / device-stream。
 * `remote exec` 越しの device-stream も含む)、または配信ヘルパー(fleetest-simstream /
 * fleetest-androidstream / fleetest-devicepoll)であるもの。
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
      // **maxBuffer を明示する** —— Node の既定は 1MB で、`ps -axo command=` は
      // 引数の長い行(xcodebuild・emulator・fleetest のサブプロセス)が並ぶと簡単に超える。
      // 超えると ERR_CHILD_PROCESS_STDIO_MAXBUFFER で**掃除が黙って無効化される**
      // (2026-08-17 の実害: 20台構成で毎回失敗していた)。監視対象が多い環境ほど
      // 掃除が要るのに、多いほど効かなくなる向きだった。monitorPanel.ts の ps も同じ 8MB
      execFile("ps", ["-axo", "pid=,ppid=,command="], { maxBuffer: 8 * 1024 * 1024, env: childEnv() }, (error, stdout) => {
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
