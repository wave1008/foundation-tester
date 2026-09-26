// リモート実行の順番待ち上限(fleetest.remoteWaitLock)の既定値が3箇所で一致していることの検証。
// 設定タブは既定値を**入力欄の初期値**として出し、空欄・不正値のときもそこへ戻すので、ズレると
// 表示された秒数と実際に待つ秒数が食い違う(表示も実行も成功するので気付けない)。
//
// 同期相手:
//   vscode-fleetest/package.json        fleetest.remoteWaitLock.default … 設定の既定
//   vscode-fleetest/src/config.ts       readConfig のフォールバック     … 実際に run へ渡る値の既定
//   vscode-fleetest/src/monitorPanel.ts sendInitialState の default     … 設定タブの初期値
//
// **期待値はリテラルで持つ**(production の定数を読み直さない)—— 他のテストが値を明示している
// と production の既定を1度も通らず、既定を 0(待たない)へ戻す変更が緑のまま通る。
// 3600 秒(1 時間)の根拠は src/config.ts の remoteWaitLock のコメント(run 1 本が 10 分前後なので
// 先客が数本並んでいても待ち切れる長さ・期限は進捗で延ばさない)。**この数字を動かすときは根拠も
// 一緒に直す**。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
/** 既定は「待つ」。0(待たずに失敗)へ戻す変更をこのリテラルで止める */
const EXPECTED_DEFAULT_SECONDS = 3600;

test("リモートの順番待ち秒数の既定が package.json / config.ts / 設定タブで一致する", () => {
  const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));
  const configDefault =
    pkg.contributes?.configuration?.properties?.["fleetest.remoteWaitLock"]?.default;
  assert.equal(configDefault, EXPECTED_DEFAULT_SECONDS,
    "package.json の fleetest.remoteWaitLock.default が既定とズレています");

  const config = readFileSync(path.join(ROOT, "src/config.ts"), "utf8");
  const configMatch = config.match(/get<number>\("remoteWaitLock",\s*(\d+)\)/);
  assert.ok(configMatch, "config.ts から remoteWaitLock のフォールバック値を抽出できません");
  assert.equal(Number(configMatch[1]), EXPECTED_DEFAULT_SECONDS,
    "config.ts の readConfig が使う既定が package.json とズレています");

  const panel = readFileSync(path.join(ROOT, "src/monitorPanel.ts"), "utf8");
  const panelMatch = panel.match(/type:\s*"remoteWaitLock"[\s\S]{0,200}?default:\s*(\d+)/);
  assert.ok(panelMatch, "monitorPanel.ts から remoteWaitLock の default を抽出できません");
  assert.equal(Number(panelMatch[1]), EXPECTED_DEFAULT_SECONDS,
    "設定タブへ送る既定値が他の2箇所とズレています");
});
