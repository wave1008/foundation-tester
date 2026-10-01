// 配信の2条件の切り替わりを出力へ残す判定(src/streamVisibilityLog.ts)。
// モニター内のタブ切替は条件に入れない(張り直しの間タイルが映らないため。ユーザー決定)。
// 守る3つ: 初回と変化なしは言わない(タブを開くたび・当て直しのたびに行を積まない)/
// 畳んだときは外れた条件を全部名指しする / 戻ったら再開を言う。
// 畳む破棄は意図的で配信側が何も言わないため、run と重なると「run が配信を止めた」と取り違えた。

import assert from "node:assert/strict";
import { test } from "node:test";
import { streamVisibilityChange, streamVisible } from "../src/streamVisibilityLog";

const shown = { panelVisible: true, showStreamDuringRun: true };

test("2条件がそろったときだけ配信する", () => {
  assert.equal(streamVisible(shown), true);
  assert.equal(streamVisible({ ...shown, panelVisible: false }), false);
  assert.equal(streamVisible({ ...shown, showStreamDuringRun: false }), false);
});

test("初回と変化なしは言わない", () => {
  assert.equal(streamVisibilityChange(undefined, shown), undefined);
  assert.equal(streamVisibilityChange(undefined, { ...shown, panelVisible: false }), undefined);
  assert.equal(streamVisibilityChange(true, shown), undefined);
  assert.equal(streamVisibilityChange(false, { ...shown, showStreamDuringRun: false }), undefined);
});

test("畳んだときは外れた条件を全部名指しする", () => {
  assert.deepEqual(streamVisibilityChange(true, { ...shown, panelVisible: false }),
    { kind: "folded", reasons: ["panelHidden"] });
  assert.deepEqual(streamVisibilityChange(true, { panelVisible: false, showStreamDuringRun: false }),
    { kind: "folded", reasons: ["panelHidden", "liveUpdateOff"] });
});

test("戻ったら再開を言う", () => {
  assert.deepEqual(streamVisibilityChange(false, shown), { kind: "resumed" });
});
