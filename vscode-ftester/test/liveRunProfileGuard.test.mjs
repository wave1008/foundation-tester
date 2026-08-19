// ライブ操作パネル連動(ftester.liveControlOnRun)が実行プロファイルを奪わないことのソース走査。
//
// liveTarget は --platform/--serial を渡し、api run 側で --profile と排他なので、
// **プロファイル設定時に連動すると --profile が黙って捨てられる**。実害(2026-08-20 の受け手報告):
//   - 対象アプリが解決できず、app 省略シナリオが全滅する(「no app could be resolved」)
//   - scenarioTimeout / record / iosSystemAlertButtons などプロファイルの設定が一切効かない
//   - 複数デバイスの並列実行が単一デバイスに潰れる
// args 分岐のコメントは元からこの条件を前提に書かれていたのに、**ガードの実装だけが抜けていた**。
// runHandler.ts は import できない(testTree.ts のトップレベル new vscode.TestTag がスタブで落ちる)
// ので、ここでは条件が式として残っていることを走査で守る。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

/** コメント行を落とす。理由書きに profile と書いてあるので、素で走査すると条件を消しても緑になる */
function codeOnly(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
}

test("ライブ連動のガードは profile が空のときだけ立つ", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/runHandler.ts"), "utf8"));
  const marker = "let liveTarget: LiveRunTarget | undefined;";
  const at = source.indexOf(marker);
  assert.notEqual(at, -1, "liveTarget の宣言が見つからない(改名したらこのテストも直す)");

  const guard = source.slice(at + marker.length).split("{")[0];
  assert.match(
    guard,
    /profile\.length === 0/,
    "ライブ連動のガードに profile 条件が無い = プロファイルが黙って捨てられる" +
      `(見つかったガード: ${guard.trim()})`,
  );
});

test("liveTarget と --profile は排他のまま(片方だけを渡す分岐)", () => {
  const source = codeOnly(fs.readFileSync(path.join(root, "src/runHandler.ts"), "utf8"));
  const at = source.indexOf("if (liveTarget) {");
  assert.notEqual(at, -1, "args の liveTarget 分岐が見つからない");

  const branch = source.slice(at, at + 600);
  assert.match(branch, /--platform/, "liveTarget 側は platform/serial を渡すこと");
  assert.match(
    branch,
    /else if \(profile\.length > 0\)/,
    "profile を渡すのは liveTarget が無いときだけ(両方渡すと api run が拒否する)",
  );
});
