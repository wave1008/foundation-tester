// esbuild.mjs
// vscode-ftester のビルドスクリプト。
//
//   node esbuild.mjs          : src/extension.ts -> dist/extension.js (1回ビルド)
//   node esbuild.mjs --watch  : 上記をウォッチモードで実行
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
}
