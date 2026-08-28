// webview の CSS に ::-webkit-scrollbar-* を書かせないソース走査。
//
// 実害(2026-08-28): フリートのスクロールバーの色を3回変えたが、**1度も見た目が変わらなかった**。
// VSCode の webview 既定スタイル(webview/browser/pre/index.html)が
// `html { scrollbar-color: var(--vscode-scrollbarSlider-background) var(--vscode-editor-background) }`
// を敷いており、scrollbar-color は継承する。Chromium は scrollbar-color が auto でない要素の
// ::-webkit-scrollbar 系の指定を**丸ごと無視する**ので、色も太さも書いたそばから死ぬ。
// 失敗は見た目が変わらないだけ = 静かなので、書けないことを機械で止める。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

/** コメントを潰す(行番号は保つ)。**判定にコメント本文を混ぜない** —— 混ぜると、
 *  指定を消しても「なぜそう書くか」の注記が残っているだけでテストが通ってしまう。 */
function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, " "));
}

function cssFiles(dir) {
  const found = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      found.push(...cssFiles(full));
    } else if (entry.name.endsWith(".css")) {
      found.push(full);
    }
  }
  return found;
}

test("webview の CSS に ::-webkit-scrollbar-* を書かない(Chromium に無視される)", () => {
  const files = cssFiles("src/webview");
  assert.ok(files.length >= 2, `走査対象が見つからない: ${files.length}`);
  const offenders = [];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    // コメント内の言及(なぜ書けないかの説明)は許す。行番号を保つため改行だけ残して潰す。
    const code = stripComments(source);
    code.split("\n").forEach((line, index) => {
      if (line.includes("::-webkit-scrollbar")) {
        offenders.push(`${file}:${index + 1}: ${source.split("\n")[index].trim()}`);
      }
    });
  }
  assert.deepEqual(
    offenders,
    [],
    "スクロールバーの色・太さは標準プロパティ(scrollbar-color / scrollbar-width)で書く",
  );
});

test("フリートのスクロールバーは標準プロパティで指定されている", () => {
  const css = stripComments(fs.readFileSync("src/webview/monitor/style.css", "utf8"));
  const grid = css.slice(css.indexOf("\n.grid {"));
  const body = grid.slice(0, grid.indexOf("\n}"));
  assert.match(body, /scrollbar-color:/, ".grid に scrollbar-color が無いと既定色(セパレーターと同色)になる");
});
