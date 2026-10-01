// ライブ操作のレコーディングの長押し(pressPoint)が、押した秒数を記録の手(RecordedStep.duration)に入れること。
// 入れないと `fleetest api gen-scenario` の生成コードは押した長さに関わらず `holdSeconds: 1` になる
// (Swift 側の生成は FlowStep.duration を読む。境界の Swift 側は ScenarioCodeGenTests が固定)。
// MonitorLiveController は vscode を要しスタブで作れないので、monitorLiveControllerBridgeStarting.test.mjs と
// 同じくソース走査で守る。
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

test("pressPoint の記録の手は押した秒数(duration)を持つ", () => {
  const text = readFileSync(path.join(process.cwd(), "src/monitorLiveController.ts"), "utf8");
  const start = text.indexOf('case "pressPoint": {');
  assert.notEqual(start, -1, "pressPoint の分岐が見つからない");
  // 分岐の中に早期の break があるので、次の case の手前までを本体とする
  const end = text.indexOf("case ", start + 1);
  assert.notEqual(end, -1, "pressPoint の分岐の終わりが見つからない");
  const body = text.slice(start, end);
  assert.match(body, /\{ action: "press", \.\.\.locatorChainForElement\([^)]*\), duration \}/,
    "記録の手に duration を入れていない");
});
