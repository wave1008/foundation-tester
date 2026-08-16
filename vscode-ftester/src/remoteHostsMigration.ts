// remoteHostsMigration.ts
// ftester.remote.hosts(旧・VSCode 設定)から CLI の LocalConfig 登録簿への1回移行
// (docs/remote-runner.md §13「原則」・§15.2)。移行済みかどうかは「旧設定が空かどうか」で
// 判定する(専用フラグは増やさない)。activate() から fire-and-forget で呼ぶ想定
// (compatCheck.ts の checkFtesterCompat と同じパターン)。

import * as vscode from "vscode";
import { t } from "./i18n";
import { importRemoteHosts, type RemoteHostsCliDeps } from "./remoteHostsController";
import { normalizeRemoteHosts } from "./remoteRunArgs";

/**
 * 旧設定に要素があれば CLI へ import し、成功したら旧設定を空にして1回だけ通知する。
 * CLI 呼び出しが失敗した場合は旧設定を空にしない(次回起動時に再試行させる)。
 */
export async function migrateRemoteHostsToCli(deps: RemoteHostsCliDeps): Promise<void> {
  const configuration = vscode.workspace.getConfiguration("ftester");
  const entries = normalizeRemoteHosts(configuration.get<unknown>("remote.hosts", []));
  if (entries.length === 0) {
    return;
  }
  const imported = await importRemoteHosts(deps, entries);
  if (imported === undefined) {
    deps.outputChannel.appendLine(
      `[remote-hosts] migration deferred: import of ${String(entries.length)} legacy host(s) failed`,
    );
    return;
  }
  // 既存の remote.* 書き込み(monitorPanel.ts の setRemoteConfig)と同じ ConfigurationTarget を使う
  // (package.json 側は "scope": "machine" 済み。§15.2 の暫定対処)。
  await configuration.update("remote.hosts", [], vscode.ConfigurationTarget.Global);
  void vscode.window.showInformationMessage(t("remoteHosts.migration.done", { count: String(entries.length) }));
}
