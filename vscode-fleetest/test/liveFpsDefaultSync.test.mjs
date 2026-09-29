// 配信の最大フレームレート(fleetest.liveFps)の既定値が3箇所で一致していること、と
// 設定が変わったら配信を張り直す配線があることの検証。
//
// 同期相手:
//   vscode-fleetest/package.json        fleetest.liveFps.default … 設定の既定
//   vscode-fleetest/src/config.ts       readConfig のフォールバック … 配信を起こすときに使う値の既定
//   vscode-fleetest/src/monitorPanel.ts postLiveFps の default   … 設定タブのプレースホルダ
//
// **期待値はリテラルで持つ**(production の定数を読み直さない)。12 fps の根拠: 配信 24fps・Android 8 並列で
// ホストの GPU が約 1〜1.5 時間で壊れ(Metal の Internal Error)、Vision の特徴量が縮退した実測がある
// (6fps ではほぼ出ない)。**この数字を動かすときは同じ負荷で測り直す**。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const EXPECTED_DEFAULT_FPS = 12;

test("配信の fps の既定が package.json / config.ts / 設定タブで一致する", () => {
  const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));
  const prop = pkg.contributes?.configuration?.properties?.["fleetest.liveFps"];
  assert.equal(prop?.default, EXPECTED_DEFAULT_FPS, "package.json の fleetest.liveFps.default が既定とズレています");
  assert.equal(prop?.minimum, 3);
  assert.equal(prop?.maximum, 30);

  const config = readFileSync(path.join(ROOT, "src/config.ts"), "utf8");
  const configMatch = config.match(/get<number>\("liveFps",\s*(\d+)\)/);
  assert.ok(configMatch, "config.ts から liveFps のフォールバック値を抽出できません");
  assert.equal(Number(configMatch[1]), EXPECTED_DEFAULT_FPS, "config.ts の既定が package.json とズレています");

  const panel = readFileSync(path.join(ROOT, "src/monitorPanel.ts"), "utf8");
  const panelMatch = panel.match(/type:\s*"liveFps"[\s\S]{0,200}?default:\s*(\d+)/);
  assert.ok(panelMatch, "monitorPanel.ts から liveFps の default を抽出できません");
  assert.equal(Number(panelMatch[1]), EXPECTED_DEFAULT_FPS, "設定タブへ送る既定値が他の2箇所とズレています");
});

// 走っている配信は起動時の fps のまま(張り直しの判定はコーデックしか見ない)。監視が無いと、設定を
// 変えても画面は何も変わらない(2026-09-29 に実際に踏んだ)
test("fleetest.liveFps の変更でタイルとライブ操作の配信を張り直す", () => {
  const panel = readFileSync(path.join(ROOT, "src/monitorPanel.ts"), "utf8");
  const start = panel.indexOf('event.affectsConfiguration("fleetest.liveFps")');
  assert.ok(start >= 0, "fleetest.liveFps の変更を監視していない");
  const block = panel.slice(start, start + 300);
  assert.ok(block.includes("this.deviceStream.restartAllStreams()"), "タイルの配信を張り直していない");
  assert.ok(block.includes("this.live.restartStream()"), "ライブ操作の配信を張り直していない");
});
