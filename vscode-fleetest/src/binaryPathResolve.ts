// fleetest CLI バイナリパスの解決(vscode 非依存。config.ts が使う。node --test から直接検証可)。
// clone 構成(foundation-tester を開く)は .build/debug/fleetest、外部パッケージ構成(受け手のパッケージを開く)は
// グローバル導入した fleetest を PATH から解決する。

import * as fs from "node:fs";
import * as path from "node:path";

/**
 * PATH から実行可能な `fleetest` を探す(同期。PATH はセッション中不変なので都度スキャンで十分)。
 * 見つからなければ undefined。
 */
export function findFleetestOnPath(pathEnv: string | undefined = process.env.PATH): string | undefined {
  const dirs = (pathEnv ?? "").split(path.delimiter).filter((d) => d.length > 0);
  for (const dir of dirs) {
    const candidate = path.join(dir, "fleetest");
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
 * 解決順: 設定値(絶対 or ワークスペース相対)が実在すればそれ → PATH の fleetest → 実在しなくても
 * 設定値(未ビルド時の既存エラー経路に委ねる)。clone 構成は前者、外部パッケージ構成は PATH。
 */
export function resolveBinaryPath(workspaceRoot: string, raw: string): string {
  const configured = path.isAbsolute(raw) ? raw : path.join(workspaceRoot, raw);
  // 覚えた実体を先に使う: リンクの作り直しの瞬間は existsSync(configured) が false になり、下の PATH の別の fleetest へ切り替わる
  const cached = realByLink.get(configured);
  if (cached && fs.existsSync(cached)) {
    return cached;
  }
  if (fs.existsSync(configured)) {
    return realBinaryPath(configured);
  }
  const onPath = findFleetestOnPath();
  return onPath ? realBinaryPath(onPath) : configured;
}

// 解決できた実体だけを覚える(起動のたびに解決すると、その解決が同じ窓に当たる)。キー = リンクを経たパス
const realByLink = new Map<string, string>();
const linkDirByReal = new Map<string, string>();

/**
 * 起動に使う実体のパス。**`.build/debug` は SwiftPM がビルドのたびに消して作り直すリンク**で、その間(実測 約 0.8ms。
 * run はシナリオの製品を毎回ビルドする)はリンク経由の spawn が ENOENT で落ちる。Swift 側の `ExecutablePath` と対。
 * 解決できない(その窓の中・実在しない)なら元のパス。覚えた実体が消えていたら解決し直す
 */
export function realBinaryPath(p: string): string {
  const cached = realByLink.get(p);
  if (cached && fs.existsSync(cached)) {
    return cached;
  }
  try {
    const real = fs.realpathSync(p);
    if (real !== p) {
      realByLink.set(p, real);
      linkDirByReal.set(real, path.dirname(p));
    }
    return real;
  } catch {
    return p;
  }
}

/**
 * fleetest 由来のプロセスを見分ける置き場: 実体の置き場と、リンクを経た設定上の置き場の両方。
 * 拡張と fleetest 内部は実体のパスで起こすが、端末から `.build/debug/fleetest` と打った run や MCP のランチャーはリンクのまま
 */
export function binaryDirs(binaryPath: string): string[] {
  const dirs = [path.dirname(binaryPath)];
  const linkDir = linkDirByReal.get(binaryPath);
  if (linkDir && !dirs.includes(linkDir)) {
    dirs.push(linkDir);
  }
  return dirs;
}
