// 「配信を表示する」OFF = 全台の配信と画面の取り込みを止める(マシンの負荷を下げる口)の配線を
// src/monitorPanel.ts のソースで縛る(MonitorPanelController は vscode 依存で実体を作れないため)。
// 守る2つ: 配信を動かす条件(applyDeviceStreamVisibility)にチェックボックスの値が入っている /
// 切り替えの受け口(setShowStreamDuringRun)が次の monitorDevices を待たずにその条件を当て直す。
// 条件が外れると OFF は run 中の台しか止めず、負荷は下がらない(緑のまま通る)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

const source = fs.readFileSync(path.resolve("src/monitorPanel.ts"), "utf8");

function body(startPattern, endPattern) {
  const start = source.search(startPattern);
  assert.ok(start >= 0, `${startPattern} が見つかる`);
  const rest = source.slice(start);
  const end = rest.search(endPattern);
  assert.ok(end > 0, `${endPattern} が見つかる`);
  return rest.slice(0, end);
}

test("配信を動かす条件にチェックボックスの値が入っている", () => {
  const fn = body(/private applyDeviceStreamVisibility\(\): void \{/, /\n  \}\n/);
  assert.match(fn, /this\.deviceStream\.setVisible\([^)]*this\.showStreamDuringRun[^)]*\)/);
});

test("切り替えの受け口で条件を当て直してから張り直す", () => {
  const branch = body(/case "setShowStreamDuringRun":/, /\n        break;/);
  const apply = branch.indexOf("this.applyDeviceStreamVisibility()");
  const reapply = branch.indexOf("this.deviceStream.reapply()");
  assert.ok(apply >= 0, "applyDeviceStreamVisibility を呼ぶ");
  assert.ok(reapply > apply, "当て直しは reapply より前(非表示のままだと reapply は何もしない)");
});
