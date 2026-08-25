// marqueeModel.js(フリートの範囲選択の幾何)のユニットテスト。DOM 非依存の純ロジック。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DRAG_THRESHOLD_PX,
  isDragDistance,
  marqueeRect,
  rectsOverlap,
  idsInMarquee,
  mergeMarqueeSelection,
  rectContains,
} from "../src/webview/monitor/marqueeModel.js";

const rect = (left, top, width, height) => ({ left, top, width, height });

test("しきい値未満はクリック、以上はドラッグ", () => {
  assert.equal(isDragDistance(0, 0), false);
  assert.equal(isDragDistance(DRAG_THRESHOLD_PX - 1, 0), false);
  assert.equal(isDragDistance(0, DRAG_THRESHOLD_PX), true);
  assert.equal(isDragDistance(-DRAG_THRESHOLD_PX, 0), true, "左・上へのドラッグも同じ");
});

test("どの向きへドラッグしても正の幅・高さの矩形になる", () => {
  const downRight = marqueeRect({ x: 10, y: 20 }, { x: 110, y: 220 });
  assert.deepEqual(downRight, rect(10, 20, 100, 200));
  // 右下から左上へ引いても同じ矩形
  assert.deepEqual(marqueeRect({ x: 110, y: 220 }, { x: 10, y: 20 }), downRight);
});

test("辺が触れるだけでは重なりと数えない", () => {
  const tile = rect(100, 0, 50, 50);
  assert.equal(rectsOverlap(rect(0, 0, 100, 50), tile), false, "右辺と左辺がちょうど接する");
  assert.equal(rectsOverlap(rect(0, 0, 101, 50), tile), true, "1px でも食い込めば重なり");
  assert.equal(rectsOverlap(rect(100, 50, 50, 50), tile), false, "下辺と上辺が接する");
  // 逆向き(矩形がタイルの右・下にあって接する)も同じ。4辺それぞれで見ているので両向き要る
  assert.equal(rectsOverlap(rect(150, 0, 50, 50), tile), false, "左辺と右辺が接する");
  assert.equal(rectsOverlap(rect(149, 0, 50, 50), tile), true, "1px 食い込めば重なり");
  assert.equal(rectsOverlap(rect(100, -50, 50, 50), tile), false, "上辺と下辺が接する");
});

test("重なりは一部でよい(内包・またぎ・はみ出し)", () => {
  const tile = rect(100, 100, 100, 100);
  assert.equal(rectsOverlap(rect(0, 0, 1000, 1000), tile), true, "矩形がタイルを飲み込む");
  assert.equal(rectsOverlap(rect(120, 120, 10, 10), tile), true, "矩形がタイルの中");
  assert.equal(rectsOverlap(rect(150, 0, 10, 1000), tile), true, "縦に貫く");
  assert.equal(rectsOverlap(rect(0, 0, 50, 50), tile), false, "離れている");
});

test("重なった id を並び順のまま返す", () => {
  const items = [
    { id: "a", rect: rect(0, 0, 100, 200) },
    { id: "b", rect: rect(110, 0, 100, 200) },
    { id: "c", rect: rect(220, 0, 100, 200) },
  ];
  assert.deepEqual(idsInMarquee(rect(50, 10, 100, 10), items), ["a", "b"]);
  assert.deepEqual(idsInMarquee(rect(0, 0, 400, 400), items), ["a", "b", "c"]);
  assert.deepEqual(idsInMarquee(rect(101, 0, 5, 5), items), [], "タイルの隙間では何も掴まない");
});

test("Ctrl/Cmd 無しの範囲選択は置き換え", () => {
  assert.deepEqual(mergeMarqueeSelection(["a", "b"], ["c"], false), ["c"]);
  assert.deepEqual(mergeMarqueeSelection(["a"], [], false), [], "空振りは全解除");
});

test("Ctrl/Cmd ありは前の選択を残して足す(重複は作らない・既存の順は変えない)", () => {
  assert.deepEqual(mergeMarqueeSelection(["a", "b"], ["c"], true), ["a", "b", "c"]);
  assert.deepEqual(mergeMarqueeSelection(["a", "b"], ["b", "c"], true), ["a", "b", "c"]);
  assert.deepEqual(mergeMarqueeSelection(["a"], [], true), ["a"], "空振りでも前の選択は消えない");
});

test("点の内外は4辺すべてで見る(縁は中に含む)", () => {
  const box = rect(10, 20, 100, 50);   // x 10〜110 / y 20〜70
  assert.equal(rectContains(box, { x: 10, y: 20 }), true, "左上の角");
  assert.equal(rectContains(box, { x: 110, y: 70 }), true, "右下の角");
  assert.equal(rectContains(box, { x: 9, y: 40 }), false, "左に外れる");
  assert.equal(rectContains(box, { x: 111, y: 40 }), false, "右に外れる");
  assert.equal(rectContains(box, { x: 50, y: 19 }), false, "上に外れる");
  assert.equal(rectContains(box, { x: 50, y: 71 }), false, "下に外れる");
});
