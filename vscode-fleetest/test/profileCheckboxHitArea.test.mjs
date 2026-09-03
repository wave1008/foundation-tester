// プロファイル編集フォームのチェックボックス行の当たり判定。
//
// `<label for="...">` はチェックボックスに結び付いているので、**label の箱がそのまま当たり判定**に
// なる。flex-grow を 1 にすると箱が行の右端まで伸び、**文字の無い余白を押しても切り替わる**
// (2026-09-03 の指摘)。CSS でしか決まらないので jsdom では踏めず、ここで規則を固定する。

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");

test("チェックボックス行のチェックは auto マージンでラベルを右へ飛ばさない", () => {
  // `.modal-row > input[type="checkbox"]` の margin-right: auto は残り幅をチェックと label の
  // 間に入れるので、label が伸びない設定と組み合わさるとラベルが行の右端へ飛ぶ
  const rule = css.match(
    /#run-profile-editor \.profile-checkbox-row > input\[type="checkbox"\],\s*\n#app-profile-editor \.profile-checkbox-row > input\[type="checkbox"\] \{([^}]*)\}/,
  );
  assert.ok(rule, "チェックボックス行の input 規則が読めない(セレクタの形が変わった)");
  assert.match(rule[1], /margin-right:\s*0\s*;/,
    "margin-right を 0 にしていない: 上位の auto が効いてラベルが右端へ飛ぶ");
});

test("チェックボックス行の label は伸ばさない(余白を押しても切り替わらない)", () => {
  const rule = css.match(
    /#run-profile-editor \.profile-checkbox-row > label,\s*\n#app-profile-editor \.profile-checkbox-row > label \{([^}]*)\}/,
  );
  assert.ok(rule, "チェックボックス行の label 規則が読めない(セレクタの形が変わった)");
  const flex = rule[1].match(/flex:\s*([^;]+);/);
  assert.ok(flex, "flex 指定が無い(上位の 170px 固定が効いて箱が文字より広くなる)");
  const [grow] = flex[1].trim().split(/\s+/);
  assert.equal(grow, "0",
    `flex-grow が ${grow}: label が行いっぱいに伸び、ラベル右の余白まで当たり判定になる`);
});
