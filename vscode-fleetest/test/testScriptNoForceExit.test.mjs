// `npm test` に --test-force-exit を付けない。子はテストが終わった時点で process.exit し、パイプへ書き切れていない結果を
// 捨てる = 報告の件数と落ちたテストの名前が毎回違う位置で欠ける(終了コードは正しい)。docs/maintainer-notes.md §4.3

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

test("npm test は --test-force-exit を付けない", () => {
  const scripts = JSON.parse(readFileSync("package.json", "utf8")).scripts;
  assert.match(scripts.test, /node --test /);
  assert.doesNotMatch(scripts.test, /--test-force-exit/);
});
