// 実機の自動ロック抑止トグル(設定タブ「実機」)の配線。
//
// 守るのは2つ:
//   1. **fleetest を spawn する箇所が全部 env: fleetestSpawnEnv() を渡していること**。
//      取りこぼすと、その経路だけ設定が効かない(切ったのに切れていない)。UI も CLI も
//      正常に動くので、実機を数分放置して初めて分かる。
//   2. env の中身(既定は何も足さない / off のときだけ FT_KEEP_AWAKE=0)。
//      鍵と "0" の意味の定義元は Sources/FTCore/KeepAwakePolicy.swift。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const SRC = path.join(ROOT, "src");
const REPO = path.join(ROOT, "..");

/** src 直下の .ts を読む(webview 側は fleetest を spawn しない) */
function sourceFiles() {
  return readdirSync(SRC)
    .filter((name) => name.endsWith(".ts"))
    .map((name) => ({ name, text: readFileSync(path.join(SRC, name), "utf8") }));
}

test("fleetest を spawn する箇所は全部 fleetestSpawnEnv() を渡す", () => {
  const missing = [];
  for (const { name, text } of sourceFiles()) {
    if (name === "spawnEnv.ts") continue;
    // spawn( から呼び出しの終わりまでをざっくり切り出す(オプション object はこの範囲に収まる)
    const pattern = /spawn\(([\s\S]{0,400}?)\);/g;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const call = match[1];
      // fleetest 本体を起動する呼び出しだけが対象(配信ヘルパー等は関係しない)
      if (!/binaryPath/i.test(call)) continue;
      if (!call.includes("fleetestSpawnEnv()")) {
        const line = text.slice(0, match.index).split("\n").length;
        missing.push(`${name}:${line}`);
      }
    }
  }
  assert.deepEqual(missing, [],
    `fleetest の spawn に env: fleetestSpawnEnv() が無い箇所があります: ${missing.join(", ")}`
    + "(その経路だけ「実機画面の自動ロックを抑制する」の設定が効きません)");
});

test("走査が spawn 呼び出しを実際に拾えている(空振りで緑にならない)", () => {
  const found = sourceFiles()
    .flatMap(({ text }) => [...text.matchAll(/spawn\(([\s\S]{0,400}?)\);/g)])
    .filter((match) => /binaryPath/i.test(match[1]));
  assert.ok(found.length >= 10, `fleetest の spawn を ${found.length} 箇所しか拾えていません`);
});

test("既定(抑制する)では環境に何も足さない / off のときだけ FT_KEEP_AWAKE=0", async () => {
  const { buildSpawnEnv } = await import("../src/spawnEnv.ts");
  assert.equal(buildSpawnEnv(true, { PATH: "/usr/bin" }), undefined,
    "既定では env を渡さない(親の環境をそのまま継承する)");
  const off = buildSpawnEnv(false, { PATH: "/usr/bin" });
  assert.equal(off.FT_KEEP_AWAKE, "0");
  assert.equal(off.PATH, "/usr/bin", "既存の環境変数を落としてはいけない");
});

test("鍵と off の値が Swift 側(KeepAwakePolicy)と一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/KeepAwakePolicy.swift"), "utf8");
  const ts = readFileSync(path.join(SRC, "spawnEnv.ts"), "utf8");
  const keyMatch = swift.match(/envKey\s*=\s*"([A-Z_]+)"/);
  assert.ok(keyMatch, "KeepAwakePolicy.swift から envKey を抽出できません");
  assert.ok(ts.includes(`${keyMatch[1]}: "0"`),
    `spawnEnv.ts が ${keyMatch[1]}: "0" を渡していません(Swift 側の鍵と食い違うと黙って効かない)`);
  assert.ok(swift.includes('environment[envKey] != "0"'),
    "Swift 側の off 判定が \"0\" ではありません(拡張が渡す値と食い違う)");
});
