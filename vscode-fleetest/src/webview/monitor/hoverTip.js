// マウスホバー 0.2 秒で全文を出す自前ツールチップ。
// **ネイティブ `title` は使えない**: 表示遅延がブラウザ/OS 固定(約 1 秒)で指定できないため。
//
// 使い方: setHoverTip(el, text)。text が空なら解除。ホバー検出は document への委譲なので、
// 対象要素は後から差し替えても再登録は要らない。
//
// **position:fixed で body 直下に出す**のが要点。ピル(.tile-name/.lane-name)の親は
// overflow:hidden(.tile-header/.lane-header)なので、::after 等の子要素方式だと切り取られる。

const DELAY_MS = 200;
const ATTR = 'data-hover-tip';

let tipEl = null;
let timer = null;
let current = null;

/// text が空/未指定なら属性を消す(消し忘れると空のツールチップが出る)
export function setHoverTip(el, text) {
  if (!el) { return; }
  if (text) {
    el.setAttribute(ATTR, text);
    // **ネイティブ title は必ず空にする**。自前ツールチップを付けた要素に title が残っていると、
    // 0.2 秒でこちらが出た約1秒後にネイティブも出て**同じ説明が二重に見える**(実害)。
    // 元は `if (!el.title)` だったが、それは「title を持つ要素」= 二重になる当の条件を素通しする。
    // title="" は祖先探索も打ち切るので、祖先(タイル等)由来の重複も同時に止まる
    el.title = '';
  } else {
    el.removeAttribute(ATTR);
    if (current === el) { hide(); }
  }
}

function ensureTipEl() {
  if (!tipEl) {
    tipEl = document.createElement('div');
    tipEl.className = 'hover-tip';
    tipEl.setAttribute('role', 'tooltip');
    document.body.appendChild(tipEl);
  }
  return tipEl;
}

function hide() {
  if (timer !== null) { clearTimeout(timer); timer = null; }
  current = null;
  if (tipEl) { tipEl.style.display = 'none'; }
}

/// 対象要素の直下に出し、画面外へはみ出す分だけ内側へ寄せる(下が入らなければ上へ回す)
function show(el, text) {
  const tip = ensureTipEl();
  tip.textContent = text;
  tip.style.display = 'block';
  // 先に left/top を確定させてから測る(未配置だと offsetWidth が折り返し後の値になる)
  tip.style.left = '0px';
  tip.style.top = '0px';
  const rect = el.getBoundingClientRect();
  const width = tip.offsetWidth;
  const height = tip.offsetHeight;
  const margin = 4;
  let left = rect.left;
  if (left + width > window.innerWidth - margin) { left = window.innerWidth - margin - width; }
  if (left < margin) { left = margin; }
  let top = rect.bottom + margin;
  if (top + height > window.innerHeight - margin) { top = rect.top - margin - height; }
  if (top < margin) { top = margin; }
  tip.style.left = left + 'px';
  tip.style.top = top + 'px';
}

document.addEventListener('mouseover', (e) => {
  const target = e.target instanceof Element ? e.target.closest('[' + ATTR + ']') : null;
  if (target === current) { return; }
  hide();
  if (!target) { return; }
  current = target;
  timer = setTimeout(() => {
    timer = null;
    // 遅延中に属性が消える/要素が外れることがある(タイル再描画)
    const text = current && current.isConnected ? current.getAttribute(ATTR) : null;
    if (text) { show(current, text); } else { hide(); }
  }, DELAY_MS);
});

document.addEventListener('mouseout', (e) => {
  if (!current) { return; }
  const to = e.relatedTarget;
  if (to instanceof Node && current.contains(to)) { return; }
  hide();
});

// スクロール・クリック・ウィンドウ外れで即消す(残ると位置がずれたまま貼り付く)。
// scroll は capture でないとスクロールコンテナ内の発火を拾えない
document.addEventListener('scroll', hide, true);
document.addEventListener('mousedown', hide, true);
window.addEventListener('blur', hide);
