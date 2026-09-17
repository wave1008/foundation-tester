// 実行ログビューのレーン見出し(バッジ)の配置。jsdom は外部 CSS を当てないので、規則を直接読む。

import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

function ruleBody(css, selector) {
  const start = css.indexOf(`\n${selector} {`);
  assert.notEqual(start, -1, `${selector} の規則が無い`);
  const body = css.slice(start);
  return body.slice(0, body.indexOf("\n}"));
}

test("レーン見出しのバッジは左右中央に置く", () => {
  const css = fs.readFileSync("src/webview/monitor/style.css", "utf8");
  assert.match(ruleBody(css, ".lane-header"), /justify-content:\s*center;/);
});
