// remoteRunArgs.ts
// このファイルが持つのは2つ:
// (a) リモートホスト登録簿(name/host/dir/machine)の正規化・解決・差分計算。設定タブのホスト表
//     (name/host/dir/machine)を支える。登録簿の正は CLI の LocalConfig(~/.config/fleetest/config.json。
//     `fleetest api remote-hosts` 経由。remoteHostsController.ts が spawn を担う)。
// (b) DeviceCommandSource/deviceCommandArgs。「既存デバイスを追加」ダイアログで特定ホストから
//     デバイス候補(device-catalog/installed-devices/create-device)を取得するときに使う。
//
// run のディスパッチ(その run がリモートホストへ出るかどうか)はここには一切関わらない ——
// 今は CLI がマシンプロファイルの `host` フィールドから判定する(拡張側は関与しない)。
//
// vscode 非依存の純粋関数(config.ts/remoteHostsController.ts から呼ぶ。テストは runHandler.ts を
// 経由せず直接 import する — runHandler.ts は testTree.ts 経由でトップレベル `new vscode.TestTag` を
// 実行し vscode-stub で落ちるため)。

export interface RemoteHostEntry {
  readonly name: string;
  readonly host: string;
  /** リモート専用ベースディレクトリ(tool/ = クローン, work/ = Projects・results・.build。
   * 空なら CLI 既定 "~/fleetest-runner"。そのマシンのローカルインストールと同じパスを
   * 指定してはならない — rsync --delete がユーザー資産を消す・SPM ビルドロックが競合する)。 */
  readonly dir: string;
  /** 対応する machines プロファイル名のキャッシュ(§13。真実は登録簿ではなくリモート側の
   * LocalConfig.machineName)。空文字が既定。GUI に入力欄は無い(フリート実装段で使う想定) ——
   * ここで持つのは、拡張が登録簿を読み書きするたびに他経路(`fleetest remote setup` 等)が
   * 書いた値を黙って消さないため(パススルー)。 */
  readonly machine: string;
}

/** マシンプロファイルタブ「デバイス候補のホスト」(§13 段2)。host は登録簿の name
 * (`remote exec <host>` の第1引数。raw な ssh 宛先ではなく登録名を渡す契約)。 */
export type DeviceCommandSource = { readonly kind: "local" } | { readonly kind: "remote"; readonly host: string };

/**
 * device-catalog/installed-devices/create-device をホストに応じた CLI 引数へ組み立てる
 * (docs/remote-runner.md §13「プロファイルのリモート対応」・§14「単発コマンドの転送は汎用化する」)。
 * リモートは既存の汎用転送 `remote exec <host> -- <apiArgs>` を使うだけで、個別 ssh 実装は書かない。
 * ローカルは apiArgs をそのまま返す(§13 段2 の「ローカルの挙動を1バイトも変えない」契約 —
 * この分岐が無いと既存の spawn 引数が変わってしまう)。
 */
export function deviceCommandArgs(source: DeviceCommandSource, apiArgs: readonly string[]): string[] {
  if (source.kind === "local") {
    return [...apiArgs];
  }
  return ["remote", "exec", source.host, "--", ...apiArgs];
}

/**
 * リモートホスト登録簿の生の値(JSON。`fleetest api remote-hosts` の stdout の hosts[]。
 * 外部プロセス由来で型不定)を防御的に正規化する。name も host も空の要素は捨てる
 * (識別もホストも持たない無意味な登録)。name が空なら host を name に流用する
 * (一意キーとして機能させるため)。host が空の要素も捨てない(壊れた登録として設定タブに
 * そのまま出す—黙って消すと利用者が編集で直す機会を失う)。dir/machine は欠落・型不正なら
 * 空文字(CLI 契約: 未設定でもキーは必ずあり空文字)。
 */
export function normalizeRemoteHosts(raw: unknown): RemoteHostEntry[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const result: RemoteHostEntry[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const record = item as Record<string, unknown>;
    const host = typeof record.host === "string" ? record.host.trim() : "";
    const rawName = typeof record.name === "string" ? record.name.trim() : "";
    const name = rawName.length > 0 ? rawName : host;
    if (name.length === 0 && host.length === 0) {
      continue;
    }
    const dir = typeof record.dir === "string" ? record.dir.trim() : "";
    const machine = typeof record.machine === "string" ? record.machine.trim() : "";
    result.push({ name, host, dir, machine });
  }
  return result;
}

/**
 * `fleetest api remote-hosts` の stdout(JSON.parse 済み)から hosts[] を取り出し正規化する。
 * 形が違えば undefined(呼び出し側は CLI 呼び出し失敗と同じ扱いにする)。
 */
export function parseRemoteHostsResponse(json: unknown): RemoteHostEntry[] | undefined {
  if (typeof json !== "object" || json === null) {
    return undefined;
  }
  const hosts = (json as Record<string, unknown>).hosts;
  if (!Array.isArray(hosts)) {
    return undefined;
  }
  return normalizeRemoteHosts(hosts);
}

/**
 * 設定タブが送ってくる「今の全ホスト」と、直前に把握していた登録簿を name で突き合わせ、
 * CLI へ送る差分を計算する(純粋関数。monitorPanel.ts が呼ぶ)。
 * - removedNames: previous にあって next に無い名前(`--remove` する)
 * - upserts: next のうち、同名の previous と内容(host/dir/machine)が異なる、または新規の行
 *   (`--import` は upsert なので、変わっていない行を含めて送っても副作用は無いが、
 *   変更の無いホスト操作のたびに CLI を叩かないよう絞る)
 * rename(同じ行の name を変える)は「旧名が消え新名が現れる」ので両方に現れる。呼び出し側が
 * remove→import の順で送れば正しく上書きされる。
 */
export function diffRemoteHostsForSync(
  previous: readonly RemoteHostEntry[],
  next: readonly RemoteHostEntry[],
): { readonly removedNames: readonly string[]; readonly upserts: readonly RemoteHostEntry[] } {
  const previousByName = new Map(previous.map((h) => [h.name, h] as const));
  const nextNames = new Set(next.map((h) => h.name));
  const removedNames = previous.filter((h) => !nextNames.has(h.name)).map((h) => h.name);
  const upserts = next.filter((h) => {
    const prev = previousByName.get(h.name);
    return !prev || prev.host !== h.host || prev.dir !== h.dir || prev.machine !== h.machine;
  });
  return { removedNames, upserts };
}
