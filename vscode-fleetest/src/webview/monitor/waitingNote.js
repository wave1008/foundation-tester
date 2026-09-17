// 「デバイスを待機しています」(#empty)をラインビューが非表示のときだけ下のペイン(#lanes-waiting)にも出す。
// 状態の書き手は2つ: 待機の有無 = deviceTiles.js / main.js(#empty を出し入れする箇所)、
// ラインビューの表示 = splitter.js。循環 import を作らないよう、どちらもこのモジュールだけを呼ぶ。

import { emptyMessage, lanesWaiting } from './domRefs.js';

let waiting = false;
let lineViewHidden = false;

function render() {
  lanesWaiting.style.display = waiting && lineViewHidden ? 'flex' : 'none';
}

export function setDevicesWaiting(value) {
  waiting = value;
  emptyMessage.style.display = value ? 'flex' : 'none';
  render();
}

export function setLineViewHiddenForWaiting(value) {
  lineViewHidden = value;
  render();
}
