// 実行プロファイル画面の入力欄の透かし(placeholder)が、未指定時に実際に使われる既定と一致することの検証。
// 透かしは「空欄 = この値で走る」の表示なので、Swift 側の既定だけ変えると画面が誤った値を見せ続ける
// (表示も実行も成功するので気付けない)。
//
// 同期相手:
//   defaultTimeout … Sources/FTCore/DefaultWait.swift の seconds(FTRuntime が未指定時に使う)
//   reportDir      … Sources/FTCore/RunProfile.swift の `runDoc.reportDir ?? "reports"`
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");
const html = readFileSync(path.join(ROOT, "src/monitorHtml.ts"), "utf8");

function placeholderOf(id) {
  const match = html.match(new RegExp(`id="${id}"[^>]*placeholder="([^"]*)"`));
  assert.ok(match, `monitorHtml.ts の #${id} に placeholder がありません`);
  return match[1];
}

test("defaultTimeout の透かしは DSL の既定待ち秒(DefaultWait.seconds)と一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/DefaultWait.swift"), "utf8");
  const match = swift.match(/static let seconds:\s*Double\s*=\s*([\d.]+)/);
  assert.ok(match, "DefaultWait.swift から seconds を抽出できません");
  assert.equal(Number(placeholderOf("run-profile-default-timeout")), Number(match[1]));
});

test("reportDir の透かしは未指定時の出力先と一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/RunProfile.swift"), "utf8");
  const match = swift.match(/runDoc\.reportDir \?\? "([^"]+)"/);
  assert.ok(match, "RunProfile.swift から reportDir の既定を抽出できません");
  assert.equal(placeholderOf("run-profile-report-dir"), match[1]);
});
