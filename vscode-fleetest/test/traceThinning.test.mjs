// traceThinning.js(軌跡モードの点列の間引き)のユニットテスト。DOM 非依存の純ロジック。
//
// pointermove は環境によって数msごとに発火しうるため、そのまま送ると ft_gesture /
// GestureRequest の1指あたりの点数上限(625)に触れる。2段で間引く: ①直前に残した点から
// 16ms未満は捨てる ②それでも600点を超えれば均等間引きで600点にする。どちらも先頭・末尾は必ず残す。

import assert from "node:assert/strict";
import { test } from "node:test";
import { thinTracePoints } from "../src/webview/monitor/traceThinning.js";

function point(x, t) {
  return { x, y: x, t };
}

test("thinTracePoints: 2点以下はそのまま返す", () => {
  assert.deepEqual(thinTracePoints([]), []);
  assert.deepEqual(thinTracePoints([point(0, 0)]), [point(0, 0)]);
  assert.deepEqual(thinTracePoints([point(0, 0), point(10, 50)]), [point(0, 0), point(10, 50)]);
});

test("thinTracePoints: 16ms未満の間隔の点は捨てるが、先頭・末尾は必ず残す", () => {
  const points = [
    point(0, 0), point(1, 5), point(2, 10), point(3, 20), point(4, 25), point(5, 40),
  ];
  const thinned = thinTracePoints(points);
  // 0 → 20(0→10未満は捨てる)→ 40(20→25未満は捨てる、末尾は必ず残す)
  assert.deepEqual(thinned.map((p) => p.t), [0, 20, 40]);
  assert.equal(thinned[0], points[0], "先頭は同一参照で残ること");
  assert.equal(thinned[thinned.length - 1], points[points.length - 1], "末尾は同一参照で残ること");
});

test("thinTracePoints: 600点以下ならそれ以上間引かない", () => {
  const points = Array.from({ length: 600 }, (_, i) => point(i, i * 20));
  const thinned = thinTracePoints(points);
  assert.equal(thinned.length, 600);
});

test("thinTracePoints: 600点を超えたら均等に間引き、先頭・末尾を残す", () => {
  // 間隔を広く取って①の間引きに掛からないようにする(②だけを見るため)
  const points = Array.from({ length: 1000 }, (_, i) => point(i, i * 20));
  const thinned = thinTracePoints(points);
  assert.equal(thinned.length, 600);
  assert.equal(thinned[0], points[0]);
  assert.equal(thinned[thinned.length - 1], points[points.length - 1]);
  // 間引き後も時刻は単調非減少であること
  for (let i = 1; i < thinned.length; i++) {
    assert.ok(thinned[i].t >= thinned[i - 1].t, `t が巻き戻った: ${thinned[i - 1].t} -> ${thinned[i].t}`);
  }
});

test("thinTracePoints: ①の間引きだけで600点以下に収まれば②は掛けない", () => {
  // 2000点・1msごとだが①(16ms未満を捨てる)で ~125点まで落ちるので②は発火しない
  const points = Array.from({ length: 2000 }, (_, i) => point(i, i));
  const thinned = thinTracePoints(points);
  assert.ok(thinned.length < 600, `①だけで600点未満に収まるはず: ${thinned.length}`);
  assert.equal(thinned[0], points[0]);
  assert.equal(thinned[thinned.length - 1], points[points.length - 1]);
});
