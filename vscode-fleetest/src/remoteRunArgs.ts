// remoteRunArgs.ts
// このファイルが持つのは2つ:
// (a) リモートホスト登録簿(machine/host/dir)の正規化・解決・差分計算。設定タブのホスト表
//     (マシン/ホスト/作業ベースディレクトリ)を支える。登録簿の正は CLI の LocalConfig(~/.config/fleetest/config.json。
//     `fleetest api remote-hosts` 経由。remoteHostsController.ts が spawn を担う)。
// (b) DeviceCommandSource/deviceCommandArgs。「既存デバイスを追加」ダイアログで特定のマシンから
//     デバイス候補(device-catalog/installed-devices/create-device)を取得するときに使う。
//
// run のディスパッチ(その run がリモートへ出るかどうか)はここには一切関わらない ——
// 今は CLI がマシンプロファイルの `machine` フィールドから判定する(拡張側は関与しない)。
//
// vscode 非依存の純粋関数(config.ts/remoteHostsController.ts から呼ぶ。テストは runHandler.ts を
// 経由せず直接 import する — runHandler.ts は testTree.ts 経由でトップレベル `new vscode.TestTag` を
// 実行し vscode-stub で落ちるため)。

export interface RemoteHostEntry {
  /** マシン名(設定タブで付ける名前)。プロファイルの `machine` 欄・`--host` に書くのはこれ。
   * **JSON キーは "machine"**(2026-08-26 改名。CLI が旧キー "name" も読む)。 */
  readonly machine: string;
  readonly host: string;
  /** リモート専用ベースディレクトリ(tool/ = クローン, work/ = Projects・results・.build。
   * 空なら CLI 既定 "~/fleetest-runner"。そのマシンのローカルインストールと同じパスを
   * 指定してはならない — rsync --delete がユーザー資産を消す・SPM ビルドロックが競合する)。 */
  readonly dir: string;
  /// FM 並列枠。**0 = 未設定**(dir の "" に相当。CLI 側の契約はファイル冒頭)。
  /// 機械によっては FM を2並列以上で呼ぶと壊れるため機械ごとに絞る(docs/remote-runner.md §19)
  readonly fmConcurrency?: number;
}

/** マシンプロファイルタブ「デバイス候補のマシン」(§13 段2)。machine は登録簿のマシン名
 * (= この Mac だけのエイリアス。`remote exec <machine>` の第1引数で、raw な ssh 宛先ではなく
 * 登録名を渡す契約)。**ホスト名/IP ではない**(用語は docs/remote-runner.md §0)。 */
export type DeviceCommandSource =
  | { readonly kind: "local" }
  | { readonly kind: "remote"; readonly machine: string };

/**
 * device-catalog/installed-devices/create-device を取得元のマシンに応じた CLI 引数へ組み立てる
 * (docs/remote-runner.md §13「プロファイルのリモート対応」・§14「単発コマンドの転送は汎用化する」)。
 * リモートは既存の汎用転送 `remote exec <machine> -- <apiArgs>` を使うだけで、個別 ssh 実装は書かない。
 * ローカルは apiArgs をそのまま返す(§13 段2 の「ローカルの挙動を1バイトも変えない」契約 —
 * この分岐が無いと既存の spawn 引数が変わってしまう)。
 */
export function deviceCommandArgs(source: DeviceCommandSource, apiArgs: readonly string[]): string[] {
  if (source.kind === "local") {
    return [...apiArgs];
  }
  return ["remote", "exec", source.machine, "--", ...apiArgs];
}

/**
 * リモートホスト登録簿の生の値(JSON。`fleetest api remote-hosts` の stdout の hosts[]。
 * 外部プロセス由来で型不定)を防御的に正規化する。machine も host も空の要素は捨てる
 * (識別もホストも持たない無意味な登録)。machine が空なら host のホスト部を流用する
 * (一意キーとして機能させるため)。host が空の要素も捨てない(壊れた登録として設定タブに
 * そのまま出す—黙って消すと利用者が編集で直す機会を失う)。dir は欠落・型不正なら
 * 空文字(CLI 契約: 未設定でもキーは必ずあり空文字)。**旧キー "name" も読む**(改名の互換)。
 */
/**
 * machine を省略したときの既定名: ssh 宛先からホスト部を採る(`user@` を落とす)。
 * **同期相手: Sources/FTRemote/RemoteHostRegistry.swift の defaultMachine(forHost:)**
 * (拡張は入力欄のウォーターマークと送信値に、CLI は `--import` の空 machine に使う。
 * remoteHostDefaultMachineSync.test.mjs が規則の食い違いを検出)。
 */
export function defaultMachineForHost(host: string): string {
  const trimmed = host.trim();
  const at = trimmed.lastIndexOf("@");
  return (at >= 0 ? trimmed.slice(at + 1) : trimmed).trim();
}

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
    const rawMachine = record.machine ?? record.name;  // 旧キー "name" も読む
    const trimmed = typeof rawMachine === "string" ? rawMachine.trim() : "";
    const machine = trimmed.length > 0 ? trimmed : defaultMachineForHost(host);
    if (machine.length === 0 && host.length === 0) {
      continue;
    }
    const dir = typeof record.dir === "string" ? record.dir.trim() : "";
    // **欄を落とさない** —— ここで欠けた欄は diffRemoteHostsForSync の previous 側から消え、
    // その欄だけの編集が「変更なし」と判定されて CLI へ届かなくなる(打った値が消える)
    const fm = record.fmConcurrency;
    const fmConcurrency = typeof fm === "number" && fm > 0 ? fm : 0;
    result.push({ machine, host, dir, fmConcurrency });
  }
  return result;
}

/**
 * `fleetest api remote-hosts` の stdout(JSON.parse 済み)から hosts[] を取り出し正規化する。
 * 形が違えば undefined(呼び出し側は CLI 呼び出し失敗と同じ扱いにする)。
 */
/**
 * `fleetest api remote-hosts` が返す**未設定時の FM 枠**(CLI 側 FMLock.defaultConcurrency)。
 * 拡張はこの数を GUI のウォーターマークに出すだけで、値そのものは持たない ——
 * **定数を二重に持つと片方だけ変わったときに嘘を表示する**。読めなければ undefined。
 */
/** 設定タブの固定行(この機械)。**登録簿には入らない** —— "local" は予約名で、
 *  値は CLI 側 LocalConfig.fmConcurrency に置かれる。host/machine は表示専用。 */
export interface LocalMachineEntry {
  readonly machine: "local";
  readonly host: string;
  readonly fmConcurrency: number;
}

export function parseLocalMachine(json: unknown): LocalMachineEntry | undefined {
  if (typeof json !== "object" || json === null) {
    return undefined;
  }
  const local = (json as Record<string, unknown>).local;
  if (typeof local !== "object" || local === null) {
    return undefined;
  }
  const row = local as Record<string, unknown>;
  if (typeof row.host !== "string") {
    return undefined;
  }
  return {
    machine: "local",
    host: row.host,
    fmConcurrency: typeof row.fmConcurrency === "number" && row.fmConcurrency > 0 ? row.fmConcurrency : 0,
  };
}

export function parseDefaultFMConcurrency(json: unknown): number | undefined {
  if (typeof json !== "object" || json === null) {
    return undefined;
  }
  const value = (json as Record<string, unknown>).defaultFMConcurrency;
  return typeof value === "number" && value > 0 ? value : undefined;
}

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
 * 設定タブが送ってくる「今の全ホスト」と、直前に把握していた登録簿を machine で突き合わせ、
 * CLI へ送る差分を計算する(純粋関数。monitorPanel.ts が呼ぶ)。
 * - removedNames: previous にあって next に無いマシン名(`--remove` する)
 * - upserts: next のうち、同名の previous と内容(host/dir)が異なる、または新規の行
 *   (`--import` は upsert なので、変わっていない行を含めて送っても副作用は無いが、
 *   変更の無いホスト操作のたびに CLI を叩かないよう絞る)
 * rename(同じ行のマシン名を変える)は「旧名が消え新名が現れる」ので両方に現れる。呼び出し側が
 * remove→import の順で送れば正しく上書きされる。
 */
export function diffRemoteHostsForSync(
  previous: readonly RemoteHostEntry[],
  next: readonly RemoteHostEntry[],
): { readonly removedNames: readonly string[]; readonly upserts: readonly RemoteHostEntry[] } {
  const previousByName = new Map(previous.map((h) => [h.machine, h] as const));
  const nextNames = new Set(next.map((h) => h.machine));
  const removedNames = previous.filter((h) => !nextNames.has(h.machine)).map((h) => h.machine);
  const upserts = next.filter((h) => {
    const prev = previousByName.get(h.machine);
    // **編集できる欄はすべて比較する**。1つでも漏らすと、その欄だけを変えた編集が差分ゼロと
    // 判定されて CLI へ届かず、直後に届く remoteConfig が入力を古い値へ戻す
    // (= 打った値が消える)。欄を足したらここも足す
    return !prev || prev.host !== h.host || prev.dir !== h.dir
      || (prev.fmConcurrency ?? 0) !== (h.fmConcurrency ?? 0);
  });
  return { removedNames, upserts };
}

/** `fleetest api remote-hosts` の応答のうち **hosts[] 以外の欄**の控え。
 *  拡張はこれを保持し、webview へ送り返す `remoteConfig` に載せる。 */
export interface RemoteHostsSideFields {
  readonly defaultFMConcurrency?: number;
  readonly local?: LocalMachineEntry;
}

/**
 * 控えを CLI 応答で更新する。**応答に無い欄は据え置く**(消さない)。
 *
 * **読み取り(`api remote-hosts`)だけでなく書き込み(`--import` / `--remove`)の応答からも通す。**
 * 読み取り時にしか控えないと、書き込み直後に webview へ送り返す `local` が古いままになり、
 * 固定行(この機械)に打った FM 枠が**打った瞬間に元の値へ戻る** = 変更できない、という
 * 症状になる(2026-09-02 に実際に踏んだ)。`diffRemoteHostsForSync` が hosts[] の欄を
 * 落として同じ症状を出したのと**同じ型** —— どちらも「往復の片道で欄が落ちる」。
 */
export function mergeRemoteHostsSideFields(
  previous: RemoteHostsSideFields,
  result: RemoteHostsSideFields,
): RemoteHostsSideFields {
  return {
    defaultFMConcurrency: result.defaultFMConcurrency ?? previous.defaultFMConcurrency,
    local: result.local ?? previous.local,
  };
}
