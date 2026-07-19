// ftester CLI バイナリパスの解決(vscode 非依存。config.ts が使う。node --test から直接検証可)。
// clone 構成(foundation-tester を開く)は .build/debug/ftester、外部パッケージ構成(受け手のパッケージを開く)は
// グローバル導入した ftester を PATH から解決する。

import * as fs from "node:fs";
import * as path from "node:path";

/**
 * PATH から実行可能な `ftester` を探す(同期。PATH はセッション中不変なので都度スキャンで十分)。
 * 見つからなければ undefined。
 */
export function findFtesterOnPath(pathEnv: string | undefined = process.env.PATH): string | undefined {
  const dirs = (pathEnv ?? "").split(path.delimiter).filter((d) => d.length > 0);
  for (const dir of dirs) {
    const candidate = path.join(dir, "ftester");
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // 実行不可・不在。次の PATH エントリへ。
    }
  }
  return undefined;
}

/**
 * 解決順: 設定値(絶対 or ワークスペース相対)が実在すればそれ → PATH の ftester → 実在しなくても
 * 設定値(未ビルド時の既存エラー経路に委ねる)。clone 構成は前者、外部パッケージ構成は PATH。
 */
export function resolveBinaryPath(workspaceRoot: string, raw: string): string {
  const configured = path.isAbsolute(raw) ? raw : path.join(workspaceRoot, raw);
  if (fs.existsSync(configured)) {
    return configured;
  }
  return findFtesterOnPath() ?? configured;
}
