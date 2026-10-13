import * as fs from "node:fs";
import * as path from "node:path";

/**
 * 占有の持ち主(issuerId)の表示名。既定の issuerId は `USER@hostname`(Sources/FTCore/LocalConfig.swift の
 * resolveIssuer)なので、hostname がマシン名の付いた機械なら **`USER@マシン名`** に読み替える(ユーザー決定)。
 * **読み替えは表示だけ** —— mine の判定・unlock の照合は生の issuer のまま(webview へ渡す文字だけを変える)。
 * 明示設定の issuerId(FT_ISSUER / config の issuerId)は `@` を含まないか、含んでも表に無いので素通しする。
 */
export function issuerDisplayName(issuer: string, aliases: ReadonlyMap<string, string>): string {
  const at = issuer.lastIndexOf("@");
  if (at <= 0 || at === issuer.length - 1) {
    return issuer;
  }
  const alias = aliases.get(normalizeHostName(issuer.slice(at + 1)));
  return alias === undefined ? issuer : `${issuer.slice(0, at)}@${alias}`;
}

/** ホスト名の照合キー。issuerId の hostname は ProcessInfo.hostName(`ldipc95.local` 等)、
 *  remote-hosts の `host` は `hostname -s` 相当(`LDIPC95`)なので、大小と `.local` を落として揃える */
export function normalizeHostName(host: string): string {
  return host.toLowerCase().replace(/\.local$/, "");
}

/**
 * 正規化したホスト名 → マシン名。供給元は recordingsStore.ts の readMachineAliases と同じ
 * `.fleetest/remote-hosts/<ホスト>.json` の `host` / `machineAlias`(同じ機械に複数あれば "local" を優先)。
 * **同期で読む** —— 占有の変化は稀で、読んだ結果を待たずに post すると変化の順序が入れ替わる。
 */
export function readIssuerAliases(workspaceRoot: string): Map<string, string> {
  const dir = path.join(workspaceRoot, ".fleetest", "remote-hosts");
  const aliases = new Map<string, string>();
  let files: string[];
  try {
    files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  } catch {
    return aliases;
  }
  for (const file of files) {
    let record: unknown;
    try {
      record = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    } catch {
      continue;
    }
    if (typeof record !== "object" || record === null) {
      continue;
    }
    const { host, machineAlias } = record as { host?: unknown; machineAlias?: unknown };
    if (typeof host !== "string" || host === "" || typeof machineAlias !== "string" || machineAlias === "") {
      continue;
    }
    const key = normalizeHostName(host);
    if (!aliases.has(key) || machineAlias === "local") {
      aliases.set(key, machineAlias);
    }
  }
  return aliases;
}
