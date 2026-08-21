// Shirates 準拠表(docs/shirates-parity.md)に**判定していない行**を残さない。
//
// 以前の ❌ は「検討して見送った」と「見ていない」が混ざっており、`disableHandler` は
// **理由が1行も無い ❌** のまま置かれていて、実際には CAE を跨ぐ制御に必要だった
// (2026-08-21 にユーザー指摘で採用)。表の役目は「何を持たないか」を**判定済みの形**で
// 残すことなので、印だけの行を機械で落とす。
//
// 規約: ➖(意図的に持たない)と ❌(足す価値ありと判定済み)は**必ず理由/条件を伴う**。
// ✅ / 🟡 / 🟢 は印だけでよい(実装があるので、読み手は docs/commands.md へ行ける)。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(他の doc 同期テストと同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const DOC = path.join(process.cwd(), "..", "docs", "shirates-parity.md");
/** 判定に理由が要る印 */
const NEEDS_REASON = ["➖", "❌"];

/** セル区切りは `\|`(セレクタ記法の OR を書くためのエスケープ)を跨がない。
 * 素の split("|") だと `(a\|b)` を含む行がセル数を余分に持ち、末尾から数える判定セルが
 * 本文の断片に化けて**その行が黙って検査対象から外れる**(実際に1行あった) */
function splitCells(line) {
  return line.split(/(?<!\\)\|/).map((cell) => cell.trim());
}

function verdictCells(source) {
  const rows = [];
  for (const [index, line] of source.split("\n").entries()) {
    if (!line.startsWith("|")) continue;
    const cells = splitCells(line);
    // 表の行は | A | B | C | の形(前後の空要素を含めて5要素以上)
    if (cells.length < 4) continue;
    // 凡例そのものの行(1列目が印だけ)は対象外。**行全体への部分一致で除外しない** ——
    // 「意味」等は本文の理由にも普通に現れるので、判定済みの行まで黙って免除される
    if (NEEDS_REASON.some((mark) => cells[1] === mark)) continue;
    const verdict = cells[cells.length - 2];
    if (!NEEDS_REASON.some((mark) => verdict.startsWith(mark))) continue;
    rows.push({ line: index + 1, verdict, text: line });
  }
  return rows;
}

test("➖ / ❌ の行は必ず理由(または足す条件)を書いている", () => {
  const rows = verdictCells(readFileSync(DOC, "utf8"));
  assert.ok(rows.length > 10, `判定行を抽出できていない(${rows.length} 行)`);
  const bare = rows.filter(({ verdict }) => {
    const rest = verdict.replace(/^[➖❌]/u, "").trim();
    return rest.length < 10;   // 印だけ・記号だけの行を落とす
  });
  assert.deepEqual(
    bare.map((row) => `${row.line}: ${row.text.slice(0, 80)}`),
    [],
    "判定の印だけで理由が無い行(見送るなら理由を、足すなら足す条件を書く)",
  );
});

test("判定を壊したら落ちることの確認(理由の無い行を混ぜる)", () => {
  const broken = "| `foo` | — | ❌ |\n";
  const rows = verdictCells(broken);
  assert.equal(rows.length, 1);
  assert.ok(rows[0].verdict.replace(/^[➖❌]/u, "").trim().length < 10);
});

test("セレクタ記法の `\\|` を含む行も判定対象に残る", () => {
  // エスケープが**判定セルの中**にあると、素の split("|") では末尾から数えた判定セルが
  // 理由の断片("b)` は各節を数える")に化け、印で始まらないので行ごと検査から外れる
  const escaped = "| フィルタ内 OR | 同名記法 | ➖ `(a\\|b)` は各節の和を数えるので不要 |\n";
  const rows = verdictCells(escaped);
  assert.equal(rows.length, 1, "素の split(\"|\") だとこの行が黙って検査から外れる");
  assert.ok(rows[0].verdict.startsWith("➖"));
});

test("凡例の免除は凡例表の行だけに効く(理由が本文にある行を免除しない)", () => {
  const legendRow = "| ➖ | **意図的に持たない**(理由は各行) |\n";
  assert.deepEqual(verdictCells(legendRow), [], "凡例の行そのものは対象外のまま");
  // 「意味」は本文の理由にも普通に現れる語。行全体への部分一致で免除すると判定済みの行が漏れる
  const contentRow = "| `notExist` | `dontExist` | ➖ 否定の意味が読み取りやすい |\n";
  assert.equal(verdictCells(contentRow).length, 1, "本文の行を凡例扱いで免除しないこと");
});
