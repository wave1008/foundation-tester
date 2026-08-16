// remoteRunArgs.ts
// リモートホスト登録簿(name/host/dir/machine)の正規化・解決・差分計算と、`ftester api run` への
// ディスパッチ引数の組み立て(docs/remote-runner.md §13「原則」・§15.2)。vscode 非依存の純粋関数
// (config.ts/runHandler.ts/remoteHostsController.ts から呼ぶ。テストは runHandler.ts を経由せず
// 直接 import する — runHandler.ts は testTree.ts 経由でトップレベル `new vscode.TestTag` を
// 実行し vscode-stub で落ちるため)。
//
// 登録簿の正は CLI の LocalConfig(~/.config/ftester/config.json)。拡張はここでは保持せず、
// 都度 `ftester api remote-hosts` を読み書きする(remoteHostsController.ts が spawn を担う)。
// ftester.remote.hosts(VSCode 設定)は旧版の置き場所で、起動時に1回だけ移行する
// (remoteHostsMigration.ts)。ftester.remote.target/artifacts は「今どこへ出すか」という
// UI の状態であって登録簿の実体ではないため、引き続き VSCode 設定(scope: machine)に残す。

export interface RemoteHostEntry {
  readonly name: string;
  readonly host: string;
  /** リモート専用ベースディレクトリ(tool/ = クローン, work/ = Projects・results・.build。
   * 空なら CLI 既定 "~/ftester-runner"。そのマシンのローカルインストールと同じパスを
   * 指定してはならない — rsync --delete がユーザー資産を消す・SPM ビルドロックが競合する)。 */
  readonly dir: string;
  /** 対応する machines プロファイル名のキャッシュ(§13。真実は登録簿ではなくリモート側の
   * LocalConfig.machineName)。空文字が既定。GUI に入力欄は無い(フリート実装段で使う想定) ——
   * ここで持つのは、拡張が登録簿を読み書きするたびに他経路(`ftester remote setup` 等)が
   * 書いた値を黙って消さないため(パススルー)。 */
  readonly machine: string;
}

export type RemoteTargetResolution =
  | { readonly kind: "local" }
  | { readonly kind: "remote"; readonly entry: RemoteHostEntry }
  // target が hosts に無い、または一致した entry の host が空(壊れた登録)。
  // 呼び出し側はこれを「黙ってローカルで走らせる」のではなく run 中止として扱うこと
  // (「リモートで走ったつもりがローカル」という沈黙の失敗を塞ぐため)。
  | { readonly kind: "error"; readonly target: string };

/** ftester.remote.target を ftester.remote.hosts から解決する。target 空 = ローカル実行。 */
export function resolveRemoteTarget(
  target: string,
  hosts: readonly RemoteHostEntry[],
): RemoteTargetResolution {
  const trimmed = target.trim();
  if (trimmed.length === 0) {
    return { kind: "local" };
  }
  const entry = hosts.find((h) => h.name === trimmed);
  if (!entry || entry.host.trim().length === 0) {
    return { kind: "error", target: trimmed };
  }
  return { kind: "remote", entry };
}

/**
 * dir は空なら省略する契約(CLI 既定 = "~/ftester-runner"。引数を渡さないことで CLI 側の
 * 既定に委ねる)。artifacts も同じ省略契約: CLI 既定 "collect" のときは --remote-artifacts を
 * 付けず、非既定の "on-demand" のときだけ付ける。呼び出し側は --profile 実行(profile 指定あり)
 * のときのみこれを args へ足すこと(--host は CLI 側で --profile を必須とし、単一デバイス
 * 直指定の実行経路には付けない)。
 */
export function buildRemoteRunArgs(entry: RemoteHostEntry, artifacts: "collect" | "on-demand"): string[] {
  const args = ["--host", entry.host.trim()];
  const dir = entry.dir.trim();
  if (dir.length > 0) {
    args.push("--remote-dir", dir);
  }
  if (artifacts === "on-demand") {
    args.push("--remote-artifacts", "on-demand");
  }
  return args;
}

/** マシンプロファイルタブ「デバイス候補の取得元」(§13 段2)。host は登録簿の name
 * (`remote exec <host>` の第1引数。raw な ssh 宛先ではなく登録名を渡す契約)。 */
export type DeviceCommandSource = { readonly kind: "local" } | { readonly kind: "remote"; readonly host: string };

/**
 * device-catalog/installed-devices/create-device を取得元に応じた CLI 引数へ組み立てる
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
 * リモートホスト登録簿の生の値(JSON。`ftester api remote-hosts` の stdout の hosts[]、または
 * 移行元の ftester.remote.hosts 設定値。どちらも settings.json/外部プロセス由来で型不定)を
 * 防御的に正規化する。name も host も空の要素は捨てる(識別も接続先も持たない無意味な登録)。
 * name が空なら host を name に流用する(一意キーとして機能させるため)。host が空の要素は
 * 捨てない — resolveRemoteTarget が「登録はあるが host 未設定」を error として検出する経路に使う。
 * dir/machine は欠落・型不正なら空文字(CLI 契約: 未設定でもキーは必ずあり空文字)。
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
 * `ftester api remote-hosts` の stdout(JSON.parse 済み)から hosts[] を取り出し正規化する。
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
