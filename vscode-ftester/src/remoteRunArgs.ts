// remoteRunArgs.ts
// リモートホスト設定(ftester.remote.hosts/target)の正規化・解決と、`ftester api run` への
// ディスパッチ引数の組み立て(docs/remote-runner.md §12)。vscode 非依存の純粋関数(config.ts/
// runHandler.ts から呼ぶ。テストは runHandler.ts を経由せず直接 import する — runHandler.ts は
// testTree.ts 経由でトップレベル `new vscode.TestTag` を実行し vscode-stub で落ちるため)。

export interface RemoteHostEntry {
  readonly name: string;
  readonly host: string;
  /** リモート専用ベースディレクトリ(tool/ = クローン, work/ = Projects・results・.build。
   * 空なら CLI 既定 "~/ftester-runner"。そのマシンのローカルインストールと同じパスを
   * 指定してはならない — rsync --delete がユーザー資産を消す・SPM ビルドロックが競合する)。 */
  readonly dir: string;
  readonly session: "asuser" | "direct";
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
 * 既定に委ねる)。session は "direct" のときだけ明示し、"asuser"(CLI 既定)は省略する。
 * 呼び出し側は --profile 実行(profile 指定あり)のときのみこれを args へ足すこと
 * (--host は CLI 側で --profile を必須とし、単一デバイス直指定の実行経路には付けない)。
 */
export function buildRemoteRunArgs(entry: RemoteHostEntry): string[] {
  const args = ["--host", entry.host.trim()];
  const dir = entry.dir.trim();
  if (dir.length > 0) {
    args.push("--remote-dir", dir);
  }
  if (entry.session === "direct") {
    args.push("--remote-session", "direct");
  }
  return args;
}

/**
 * ftester.remote.hosts の生設定値(JSON、settings.json 由来なので型不定)を防御的に正規化する。
 * name も host も空の要素は捨てる(識別も接続先も持たない無意味な登録)。name が空なら host を
 * name に流用する(一意キーとして機能させるため)。host が空の要素は捨てない —
 * resolveRemoteTarget が「登録はあるが host 未設定」を error として検出する経路に使うため。
 * session は "asuser"/"direct" 以外なら "asuser" に落とす(config.ts の旧読み出しと同じ防御)。
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
    const session = record.session === "direct" ? "direct" : "asuser";
    result.push({ name, host, dir, session });
  }
  return result;
}
