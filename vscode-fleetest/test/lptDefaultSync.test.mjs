// LPT の実績走査 run 数の既定値が3箇所で一致していることの検証。
// 設定タブは既定値を**入力欄の初期値**として出し、空欄・不正値のときもそこへ戻すので、ズレると
// 表示された件数と実際に走る件数が食い違う(表示も実行も成功するので気付けない)。
//
// 同期相手:
//   Sources/fleetest/LPTOrdering.swift  defaultHistoryRuns   … CLI の既定
//   vscode-fleetest/package.json        fleetest.lptHistoryRuns.default … 設定の既定
//   vscode-fleetest/src/monitorPanel.ts sendInitialState の default … 設定タブの初期値
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

test("LPT の実績 run 数の既定値が Swift / package.json / 拡張で一致する", () => {
  const swiftSource = readFileSync(
    path.join(REPO, "Sources/fleetest/LPTOrdering.swift"), "utf8");
  const swiftMatch = swiftSource.match(/defaultHistoryRuns\s*=\s*(\d+)/);
  assert.ok(swiftMatch, "LPTOrdering.swift から defaultHistoryRuns を抽出できません");
  const swiftDefault = Number(swiftMatch[1]);

  const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));
  const configDefault =
    pkg.contributes?.configuration?.properties?.["fleetest.lptHistoryRuns"]?.default;
  assert.equal(configDefault, swiftDefault,
    "package.json の fleetest.lptHistoryRuns.default が Swift 側とズレています");

  const panel = readFileSync(path.join(ROOT, "src/monitorPanel.ts"), "utf8");
  const panelMatch = panel.match(/type:\s*"lptHistoryRuns"[\s\S]{0,200}?default:\s*(\d+)/);
  assert.ok(panelMatch, "monitorPanel.ts から lptHistoryRuns の default を抽出できません");
  assert.equal(Number(panelMatch[1]), swiftDefault,
    "設定タブへ送る既定値が Swift 側の既定とズレています");
});
