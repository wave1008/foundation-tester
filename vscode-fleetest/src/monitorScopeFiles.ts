// モニターの監視対象を決めるファイルが変わったときにモニターを再起動するかの判定。
// `api monitor --profile P` は P の devices を**起動時に1回だけ**読むので、台を外しても
// 再起動するまでタイルに残る。`--profile` 省略時は全実行プロファイルの和集合が対象になるため、
// 選択中プロファイルが無い間はどの実行プロファイルの変化も監視対象になりうる。
// 判定は vscode 非依存(monitorScopeFiles.test.mjs)。
// 配線は monitorProfilesController.ts の FileSystemWatcher → MonitorPanelDeps.restartMonitor。

/** 実行プロファイルの変化が監視対象になりうるか。選択中の実行プロファイルが無いときは
 * 全実行プロファイルの和集合が対象なので、どのファイルの変化も対象になる。選択中があるときは
 * そのファイルだけが対象(他の実行プロファイルの編集は監視対象に影響しない = 再起動で配信を切らない)。 */
export function monitorRestartNeeded(name: string, selectedProfile: string): boolean {
  return selectedProfile === "" || name === selectedProfile;
}

/** 実行プロファイルのうち `api monitor` が読むのは `devices` だけ
 * (Sources/fleetest/ApiMonitorCommand.swift の RunProfileScope)。その指紋を返す。
 * 読めない・オブジェクトでないなら null(= 判定できないので再起動する側へ倒す)。
 * **プロファイル画面は1操作ごとに自動保存する**ので、これで絞らないと FM のチェック1つでも
 * 配信が張り直しになる。monitor が読むキーを増やしたらここにも足す */
export function runProfileScopeKey(text: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  const source = parsed as Record<string, unknown>;
  return JSON.stringify(source.devices ?? null);
}

/** 監視スコープが変わったか。前回の指紋が無い(初見)・今回が読めないときは「変わった」側へ倒す */
export function runProfileScopeChanged(previous: string | undefined, next: string | null): boolean {
  return previous === undefined || next === null || previous !== next;
}

/** 実行プロファイルの変更でモニターを再起動するか。スコープで絞るのは**フォームの自動保存だけ**:
 * - 手編集(フォームが最後に書いた内容と違う)は常に再起動 —— `api monitor` は実行プロファイルを
 *   **全キーごとデコードする**ので、無関係な欄の型を壊すと起動に失敗して give-up し、その欄を
 *   直しても devices は変わらないので戻らない
 * - 手編集の後の最初のフォーム保存も再起動(手編集で落ちたモニターをフォームで直す経路)
 * - それ以外のフォーム保存は devices が変わったときだけ */
export function runProfileNeedsRestart(change: {
  fromForm: boolean;
  editedOutsideBefore: boolean;
  previousKey: string | undefined;
  nextKey: string | null;
}): boolean {
  return !change.fromForm || change.editedOutsideBefore || runProfileScopeChanged(change.previousKey, change.nextKey);
}

/** ファイル変化をまとめる窓(ms)。台の削除は複数の実行プロファイルへ続けて書き、watcher は
 * 1書き込みごとに発火する。1回の再起動にまとめるための幅で、尽きたら(窓の後に来た変化は)
 * もう1回再起動するだけ。 */
export const MONITOR_RESTART_DEBOUNCE_MS = 500;
