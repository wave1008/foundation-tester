// デバイスモニターの「すべて選択」の既定値(未保存のワークスペース)は ON。**決めるのはホスト**(workspaceState.get の
// 第2引数)—— ready 後に必ず webview へ送るので、webview の初期値(deviceTiles.js の selectAllOn)は復元が届くまでの
// 仮の値にすぎない。既定値をリテラルで固定する(戻す変更が緑のまま通らないように)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

const source = fs.readFileSync(path.resolve("src/monitorPanel.ts"), "utf8");

test("ホストの既定は ON", () => {
  assert.match(source, /workspaceState\.get<boolean>\("monitor\.selectAllDevices", true\)/);
});

test("ready で保存値(未保存なら既定)を webview へ送る", () => {
  assert.match(source, /this\.post\(\{ type: "selectAllDevices", value: this\.selectAllDevices \}\)/);
});
