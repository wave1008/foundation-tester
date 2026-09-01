// languageChangeRelocalize.test.mjs
// fleetest.language 変更ハンドラ本体 handleLanguageChange(src/languageChangeHandler.ts)の検証。
// extension.ts からは分離してあり(理由は同ファイル冒頭コメント参照)、vscode を一切介さず直接呼べる。

import assert from "node:assert/strict";
import { test } from "node:test";

import { handleLanguageChange } from "../src/languageChangeHandler";

test("handleLanguageChange: setLocale → ツリー再構築 → 全パネルの relocalize の順で呼ぶ", () => {
  const calls = [];
  handleLanguageChange({
    setLocale: () => calls.push("setLocale"),
    isRunActive: () => false,
    rebuildTestTree: () => calls.push("rebuildTestTree"),
    relocalizePanels: [
      () => calls.push("live"),
      () => calls.push("monitor"),
      () => calls.push("healReview"),
    ],
  });
  assert.deepEqual(calls, ["setLocale", "rebuildTestTree", "live", "monitor", "healReview"]);
});

test("handleLanguageChange: 実行中は rebuildTestTree を呼ばないが、relocalize は呼ぶ(実行中の run を壊さないため)", () => {
  const calls = [];
  handleLanguageChange({
    setLocale: () => calls.push("setLocale"),
    isRunActive: () => true,
    rebuildTestTree: () => calls.push("rebuildTestTree"),
    relocalizePanels: [() => calls.push("panel")],
  });
  assert.deepEqual(calls, ["setLocale", "panel"]);
});

test("handleLanguageChange: relocalizePanels の全件(3パネルぶん)を1回ずつ呼ぶ", () => {
  let count = 0;
  const relocalizePanels = Array.from({ length: 3 }, () => () => {
    count += 1;
  });
  handleLanguageChange({
    setLocale: () => {},
    isRunActive: () => false,
    rebuildTestTree: () => {},
    relocalizePanels,
  });
  assert.equal(count, 3);
});
