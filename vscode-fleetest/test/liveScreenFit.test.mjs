// liveScreenFit.js(「ライブ操作」タブの画面表示サイズ)のユニットテスト。DOM 非依存の純ロジック。
//
// 守っているのは「同じ画面なら表示サイズが動かない」こと。絵の供給元は配信(長辺 900px)と
// snapshot(原寸)の2つあり、さらに配信の IOSurface はシステムダイアログの表示などで寸法が
// 変わる。実害(2026-09-21): システムダイアログが出ると画像が小さくなった。

import assert from "node:assert/strict";
import { test } from "node:test";
import { displayAspect, fitScreenSize } from "../src/webview/monitor/liveScreenFit.js";

const SCREEN = { width: 402, height: 874 };

test("displayAspect: 画面サイズがあればそれを使う(絵の解像度は見ない)", () => {
  const fromScreen = displayAspect(SCREEN, { w: 900, h: 1956 });
  assert.equal(fromScreen, 402 / 874);
  // 絵の解像度が変わっても答えは同じ
  assert.equal(displayAspect(SCREEN, { w: 1206, h: 2622 }), fromScreen);
  assert.equal(displayAspect(SCREEN, { w: 0, h: 0 }), fromScreen);
});

test("displayAspect: 画面サイズがまだ無いときだけ絵の自然サイズに落ちる", () => {
  assert.equal(displayAspect(null, { w: 1206, h: 2622 }), 1206 / 2622);
  assert.equal(displayAspect({ width: 0, height: 0 }, { w: 1206, h: 2622 }), 1206 / 2622);
});

test("displayAspect: どちらも無ければ null", () => {
  assert.equal(displayAspect(null, { w: 0, h: 0 }), null);
  assert.equal(displayAspect(null, null), null);
});

// 実害そのもの: 配信(900x1956)と snapshot(1206x2622)で表示サイズが違ってはいけない。
test("fitScreenSize: 絵の解像度が変わっても表示サイズは同じ", () => {
  const aspect = displayAspect(SCREEN, { w: 900, h: 1956 });
  const a = fitScreenSize(aspect, 800);
  const b = fitScreenSize(displayAspect(SCREEN, { w: 1206, h: 2622 }), 800);
  assert.deepEqual(a, b);
  assert.equal(a.height, 800, "高さは pane の残りいっぱいを使う");
  assert.equal(a.width, 800 * (402 / 874));
});

test("fitScreenSize: 手動幅があれば幅で頭打ちにし、縦横比は保つ", () => {
  const aspect = displayAspect(SCREEN, null);
  const size = fitScreenSize(aspect, 800, 200);
  assert.equal(size.width, 200, "幅の上限に収まること");
  assert.ok(Math.abs(size.width / size.height - aspect) < 1e-9, "縦横比が崩れないこと");
  assert.ok(size.height < 800, "幅で制限されたぶん高さも下がること");
});

test("fitScreenSize: 幅に余裕があれば高さで決まる", () => {
  const aspect = displayAspect(SCREEN, null);
  assert.deepEqual(fitScreenSize(aspect, 800, 10000), fitScreenSize(aspect, 800));
});

test("fitScreenSize: 比が分からない・高さが無いときは null(呼び出し側が絵に任せる)", () => {
  assert.equal(fitScreenSize(null, 800), null);
  assert.equal(fitScreenSize(0.5, 0), null);
});
