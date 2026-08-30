// モニターの監視対象を決めるファイルが変わったときにモニターを再起動するかの判定。
// `api monitor` はマシンプロファイル(と選択中の実行プロファイル)を**起動時に1回だけ**読むので、
// 台を外しても再起動するまでタイルに残る。判定は vscode 非依存(monitorScopeFiles.test.mjs)。
// 配線は monitorProfilesController.ts の FileSystemWatcher → MonitorPanelDeps.restartMonitor。

export type ScopeFileKind = "machine" | "run";

/** マシンプロファイルは常に対象(プロファイル未選択時は machines/ を全部畳むので、どの1枚でも
 * 監視対象が変わりうる)。実行プロファイルは**選択中のものだけ**(他の実行プロファイルの編集は
 * 監視対象に影響しない = 再起動で配信を切らない)。 */
export function monitorRestartNeeded(kind: ScopeFileKind, name: string, selectedProfile: string): boolean {
  if (kind === "machine") {
    return true;
  }
  return selectedProfile !== "" && name === selectedProfile;
}

/** ファイル変化をまとめる窓(ms)。台の削除は「実行プロファイル N 枚 → マシンプロファイル 1 枚」を
 * 続けて書き、watcher は1書き込みごとに発火する。1回の再起動にまとめるための幅で、
 * 尽きたら(窓の後に来た変化は)もう1回再起動するだけ。 */
export const MONITOR_RESTART_DEBOUNCE_MS = 500;
