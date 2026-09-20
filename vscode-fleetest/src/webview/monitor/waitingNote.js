// 「デバイスを待機しています」(#empty)をラインビューが非表示のときだけ下のペイン(#lanes-waiting)にも出す。
// 状態の書き手は3つ: 待機の有無 = deviceTiles.js / main.js(#empty を出し入れする箇所)、
// ラインビューの表示・グリッドビューの開閉 = splitter.js。循環 import を作らないよう、
// どれもこのモジュールだけを呼ぶ。
// **#lanes-waiting は inline の display で出し入れする**(CSS の畳み規則はここに勝てない)ので、
// グリッドビューを畳んだかどうかもこの1箇所で解く。

import { emptyMessage, lanesWaiting } from './domRefs.js';

let waiting = false;
let lineViewHidden = false;
let gridViewHidden = false;

function render() {
  lanesWaiting.style.display = waiting && lineViewHidden && !gridViewHidden ? 'flex' : 'none';
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

export function setGridViewHiddenForWaiting(value) {
  gridViewHidden = value;
  render();
}
