// install.sh のステップ7.6(受け手の CLAUDE.md へ入口ブロックを置く)の破壊耐性。
//
// **これは利用者の資産を書き換える唯一の箇所**なので、壊し方を固定して守る。
// 2026-08-06 に実際にデータを消した: `end` マーカーだけ壊れた CLAUDE.md に対し、
// 素朴な「最初の begin 〜 最初の end」置換が、
//   1回目 = 末尾に2つ目のブロックを追記 → 2回目 = 間に挟まれた利用者の記述ごと置換
// という順で**黙って消した**。以後、マーカーが1組でなければ何も書かない。
//
// install.sh の python ヒアドキュメントを抜き出してそのまま実行する(実装の写しを置かない —
// 写すと本体だけ直したときにテストが古い実装を守り続ける)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");

/** install.sh の `python3 - "$WORK_DIR/CLAUDE.md" <<'GUIDE' … GUIDE` から本体を取り出す。 */
function guideScript() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const begin = source.indexOf("<<'GUIDE'\n");
  assert.ok(begin > 0, "install.sh に GUIDE ヒアドキュメントが無い(ステップ7.6 が消えた?)");
  const body = source.slice(begin + "<<'GUIDE'\n".length);
  const end = body.indexOf("\nGUIDE\n");
  assert.ok(end > 0, "GUIDE ヒアドキュメントの終端が見つからない");
  return body.slice(0, end);
}

/** 与えた CLAUDE.md の内容(null = ファイル無し)に対してステップ7.6 を1回流す。 */
function run(initial) {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-claude-md-"));
  try {
    const script = path.join(dir, "guide.py");
    writeFileSync(script, guideScript());
    const target = path.join(dir, "CLAUDE.md");
    if (initial !== null) writeFileSync(target, initial);
    const verb = execFileSync("python3", [script, target], { encoding: "utf8" });
    return { verb, text: existsSync(target) ? readFileSync(target, "utf8") : null };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** 2回連続で流す(冪等性と「2回目に消える」形の検出)。 */
function runTwice(initial) {
  const first = run(initial);
  return { first, second: run(first.text) };
}

const USER_TEXT = "# 我が社のアプリ\n\n社内ルール: PR は必ず2人レビュー。\n";

test("ファイルが無ければ作り、2回目は変えない(冪等)", () => {
  const { first, second } = runTwice(null);
  assert.equal(first.verb, "created");
  assert.equal(second.verb, "unchanged");
  assert.equal(first.text, second.text);
  assert.match(first.text, /ftester:begin/);
});

test("既存の CLAUDE.md には追記し、利用者の記述を残す", () => {
  const { first, second } = runTwice(USER_TEXT);
  assert.equal(first.verb, "appended to");
  assert.equal(second.verb, "unchanged");
  assert.ok(first.text.includes("社内ルール: PR は必ず2人レビュー。"));
});

test("マーカーが1組なら中身だけ差し替え、外側には触れない", () => {
  const stale = USER_TEXT + "\n<!-- ftester:begin -->\n## 古い内容\n<!-- ftester:end -->\n";
  const { verb, text } = run(stale);
  assert.equal(verb, "refreshed");
  assert.ok(text.includes("社内ルール: PR は必ず2人レビュー。"), "利用者の記述が消えた");
  assert.ok(!text.includes("## 古い内容"), "ブロックの中身が更新されていない");
  assert.equal(text.match(/ftester:begin/g).length, 1);
});

// ここから下が本題。**壊れたマーカーでは1バイトも書かない**。
// どれか1つでも書き込みに転ぶと、利用者の CLAUDE.md が黙って削れる。

test("end マーカーが欠けていたら何も書かない(2回流しても消えない)", () => {
  const damaged = "<!-- ftester:begin -->\n## 古い\n" + USER_TEXT;
  const { first, second } = runTwice(damaged);
  assert.equal(first.verb, "damaged");
  assert.equal(second.verb, "damaged");
  assert.equal(second.text, damaged, "壊れたマーカーのファイルを書き換えてはいけない");
});

test("begin が2つあったら何も書かない", () => {
  const damaged = "<!-- ftester:begin -->\na\n<!-- ftester:end -->\n"
    + USER_TEXT
    + "<!-- ftester:begin -->\nb\n<!-- ftester:end -->\n";
  const { verb, text } = run(damaged);
  assert.equal(verb, "damaged");
  assert.equal(text, damaged);
});

test("begin と end が逆順でも何も書かない", () => {
  const damaged = "<!-- ftester:end -->\n" + USER_TEXT + "<!-- ftester:begin -->\n";
  const { verb, text } = run(damaged);
  assert.equal(verb, "damaged");
  assert.equal(text, damaged);
});
