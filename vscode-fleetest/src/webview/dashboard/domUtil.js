// domUtil.js
// DOM 組み立ての小さな共通ヘルパー(render.js/runDetail.js/trend.js で共用)。innerHTML は使わない
// 方針(CLAUDE.md)を守るため、値を持つセルは必ず textContent 経由で組み立てる。

export function clearChildren(el) {
  while (el.firstChild) {
    el.removeChild(el.firstChild);
  }
}

export function td(text) {
  const cell = document.createElement('td');
  cell.textContent = text;
  return cell;
}
