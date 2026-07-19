// 起動時プレフライト: `ftester api version` を単発実行し、CLI と拡張のプロトコル版
// (protocolVersion.ts / Sources/FTCore/ProtocolVersion.swift)を照合する。ズレていれば
// activate() を止めずに警告のみ出す(fire-and-forget。extension.ts から `void` 呼び出し)。

import * as fs from "node:fs";
import * as vscode from "vscode";
import { t } from "./i18n";
import { type PipeProcess, runOneShot } from "./oneShotCli";
import { FTESTER_PROTOCOL_VERSION } from "./protocolVersion";

function protocolOf(json: unknown): number | undefined {
  if (typeof json !== "object" || json === null) {
    return undefined;
  }
  const value = (json as Record<string, unknown>).protocol;
  return typeof value === "number" ? value : undefined;
}

/**
 * `ftester api version` の結果と FTESTER_PROTOCOL_VERSION を比較し、不一致なら警告する。
 * バイナリが無い(未ビルド)場合と spawn 失敗は黙ってスキップする(fresh clone のセットアップ前に
 * 誤警告を出さないため)。activate() を1回だけ呼ぶ想定。
 */
export async function checkFtesterCompat(
  binaryPath: string,
  workspaceRoot: string,
  outputChannel: vscode.OutputChannel,
  registerChild: (proc: PipeProcess) => void,
): Promise<void> {
  if (!fs.existsSync(binaryPath)) {
    return;
  }

  let exitCode: number | null;
  let cliProtocol: number | undefined;
  try {
    const result = await runOneShot(binaryPath, workspaceRoot, ["api", "version"], outputChannel, registerChild);
    exitCode = result.exitCode;
    cliProtocol = protocolOf(result.json);
  } catch (error) {
    outputChannel.appendLine(
      t("compat.check.spawnFailedLog", { error: error instanceof Error ? error.message : String(error) }),
    );
    return;
  }

  if (exitCode !== 0 || cliProtocol === undefined) {
    void vscode.window.showWarningMessage(t("compat.mismatch.cliUnknown"));
    return;
  }

  if (cliProtocol === FTESTER_PROTOCOL_VERSION) {
    return;
  }
  if (cliProtocol < FTESTER_PROTOCOL_VERSION) {
    void vscode.window.showWarningMessage(
      t("compat.mismatch.cliOld", { cli: String(cliProtocol), ext: String(FTESTER_PROTOCOL_VERSION) }),
    );
    return;
  }
  void vscode.window.showWarningMessage(
    t("compat.mismatch.extOld", { cli: String(cliProtocol), ext: String(FTESTER_PROTOCOL_VERSION) }),
  );
}
