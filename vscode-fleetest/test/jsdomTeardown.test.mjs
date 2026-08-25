// jsdom を使う webview テストが**後始末をしている**ことの検証(ソース走査)。
//
// 契約: `pretendToBeVisual: true` の JSDOM は rAF ループを回し、さらに main.js の `setInterval` が
// 生き続けるため、**`window.close()` を呼ばないとテストプロセスが終了しない**。
// `node --test` はファイル単位の子プロセスの終了を待つので、**1本の閉じ忘れでスイート全体が止まる**。
//
// 2026-08-17 に実際に発生 —— 10ファイル中 webviewLiveDrag.test.mjs だけ後始末が無く、
// npm test が終わらなくなった(個々のテストは 1〜2 秒で、遅いテストは1つも無かった)。
// 規律自体は webviewHoverTip.test.mjs のコメントに書かれていたが、機械の歯止めが無かった。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const TEST_DIR = path.join(process.cwd(), "test");

/** コメントを落とす。**コメント中の `window.close()` を実装と数えない** ——
 * この規律はコメントで説明されている(webviewHoverTip.test.mjs 等)ので、素の includes だと
 * 後始末を消しても説明文だけで緑になる(変異テストで見つけた穴)。 */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

/** jsdom を「表示あり」で作るテストは、同じファイル内で window.close() を呼んでいること。 */
function findLeakingFiles() {
  const leaking = [];
  for (const name of readdirSync(TEST_DIR).filter((f) => f.endsWith(".test.mjs"))) {
    const source = stripComments(readFileSync(path.join(TEST_DIR, name), "utf8"));
    if (!source.includes("pretendToBeVisual")) continue;
    if (!source.includes("window.close()")) leaking.push(name);
  }
  return leaking;
}

test("jsdom(pretendToBeVisual)を使うテストは window.close() で後始末する", () => {
  assert.deepEqual(
    findLeakingFiles(),
    [],
    "window.close() が無いと main.js の setInterval が残ってプロセスが終わらず、" +
      "node --test がそのファイルの終了を待ってスイート全体が止まります。" +
      "各 test で t.after(() => window.close()) を呼んでください:\n" + findLeakingFiles().join("\n"),
  );
});

test("検知が効いている(この走査が空振りしていないこと)", () => {
  // 陽性対照: 「pretendToBeVisual を使うテスト」を実際に見つけられているか。
  // 0 件なら上のテストは常に緑になり、歯止めとして機能していない
  const visual = readdirSync(TEST_DIR)
    .filter((f) => f.endsWith(".test.mjs"))
    .filter((f) => readFileSync(path.join(TEST_DIR, f), "utf8").includes("pretendToBeVisual"));
  assert.ok(visual.length >= 5, `pretendToBeVisual を使うテストが少なすぎます(${visual.length}件)`);
});
