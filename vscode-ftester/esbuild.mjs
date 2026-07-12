// esbuild.mjs
// vscode-ftester のビルドスクリプト。
//
//   node esbuild.mjs          : src/extension.ts -> dist/extension.js と
//                                src/webview/monitor/{main.js,style.css} -> media/monitor/
//                                の両方を1回ビルド
//   node esbuild.mjs --watch  : 上記をどちらもウォッチモードで実行
//   node esbuild.mjs --tests  : test/*.test.mjs を out-test/ にバンドルする(node:test 用。
//                                src/*.ts を直接 import しているテストを Node がそのまま
//                                実行できるようにする)

import * as esbuild from "esbuild";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const watch = args.includes("--watch");
const tests = args.includes("--tests");

async function buildExtension() {
  const options = {
    entryPoints: [path.join(rootDir, "src/extension.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    outfile: path.join(rootDir, "dist/extension.js"),
    external: ["vscode"],
    sourcemap: true,
    logLevel: "info",
  };

  if (watch) {
    const ctx = await esbuild.context(options);
    await ctx.watch();
    console.log("[esbuild] watching src/ for changes...");
  } else {
    await esbuild.build(options);
  }
}

async function buildWebview() {
  const options = {
    // outdir を media/(将来複数パネル分の親)にし、outbase を src/webview/ に固定することで、
    // 各エントリの src/webview/<パネル名>/ 以下の相対パスをそのまま media/<パネル名>/ 配下へ
    // 振り分ける(monitor 用の main.js/style.css は media/monitor/ に出力される)。
    entryPoints: [
      path.join(rootDir, "src/webview/monitor/main.js"),
      path.join(rootDir, "src/webview/monitor/style.css"),
    ],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    outdir: path.join(rootDir, "media"),
    outbase: path.join(rootDir, "src/webview"),
    sourcemap: true,
    logLevel: "info",
  };

  if (watch) {
    const ctx = await esbuild.context(options);
    await ctx.watch();
    console.log("[esbuild] watching src/webview/ for changes...");
  } else {
    await esbuild.build(options);
  }
}

async function buildTests() {
  const testDir = path.join(rootDir, "test");
  const entryPoints = readdirSync(testDir)
    .filter((file) => file.endsWith(".test.mjs"))
    .map((file) => path.join(testDir, file));

  if (entryPoints.length === 0) {
    console.warn("[esbuild] test/*.test.mjs が見つかりません。");
    return;
  }

  await esbuild.build({
    entryPoints,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node18",
    outdir: path.join(rootDir, "out-test"),
    outExtension: { ".js": ".mjs" },
    sourcemap: true,
    logLevel: "info",
    // @vscode/debugadapter は CJS(require("events") 等)なので、ESM 出力にバンドルすると
    // esbuild の CJS→ESM 変換シムが Node 組み込みモジュールの動的 require に対応できず
    // 実行時エラーになる。node_modules から素の bare import として解決させる(dap.test.mjs は
    // out-test/ 配下からでも Node の ESM 解決が親ディレクトリの node_modules を辿るため解決できる)。
    external: ["@vscode/debugadapter", "@vscode/debugprotocol"],
  });
}

if (tests) {
  await buildTests();
} else {
  await buildExtension();
  await buildWebview();
}
