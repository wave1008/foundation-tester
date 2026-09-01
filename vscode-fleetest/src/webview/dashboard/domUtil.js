// domUtil.js
// DOM 組み立ての小さな共通ヘルパー(render.js/runDetail.js/trend.js で共用)。innerHTML は使わない
// 方針(CLAUDE.md)を守るため、値を持つセルは必ず textContent 経由で組み立てる。

export function clearChildren(el) {
  while (el.firstChild) {
    el.removeChild(el.firstChild);
  }
}

/** 開いたセクション(run 詳細 / 履歴)をペイン内で見える位置へ出す。どちらも長い表
 * (直近の実行 50 行・不安定なシナリオ数十行)の直後に置かれているので、出すだけだと画面外に
 * 開いて「クリックしても何も起きない」に見える(2026-09-01 実害)。スクロール領域は
 * #panel-dashboard 自身(タブペイン。window ではない)。sticky なツールバーの分は実測の高さで
 * 避ける(定数を置かない)。 */
export function revealSection(section) {
  const pane = document.getElementById('panel-dashboard');
  const toolbar = document.getElementById('dash-toolbar');
  if (!pane || !toolbar) {
    return;
  }
  const delta = section.getBoundingClientRect().top - pane.getBoundingClientRect().top - toolbar.offsetHeight;
  pane.scrollTop += delta;
}

export function td(text) {
  const cell = document.createElement('td');
  cell.textContent = text;
  return cell;
}

/** 数値・割合・所要時間のセル(右寄せ。見出しは th.num を対で付ける = monitorHtml.ts / 各表の動的見出し) */
export function tdNum(text) {
  const cell = td(text);
  cell.className = 'num';
  return cell;
}
