// rowSync.js
// 描き直しで**中身の変わらない要素を作り直さない**ための差し替え(表の行・見出しのバッジ等)。
// 作り直すとマウスを載せている要素が消え、ツールチップ(hoverTip.js)が消えて 0.2 秒後に出直す = 周期的な
// 描き直しのたびに点滅する(1Hz の host-metrics・約2秒の devices サイクル・refresh のたびの表)。
//
// 規則(呼び手の契約):
// - 比べるのは**挿入した時点の outerHTML**(WeakMap に控える)。挿入後に hoverTip.js が title を data-hover-tip へ
//   移す等で生の outerHTML は変わるので、生の値どうしは比べない。
// - **クリック等のリスナーを持つ要素は、その要素を作った元データを data-sig に載せること**(JSON 等)。
//   残した古い要素のリスナーは古いデータを捕まえているので、データが同じとき(= outerHTML が同じ)だけ残す。
// - recurseWhen(old, next) が true の位置は、要素を残したまま直下の子を同じ規則で差し替える(1段だけ。
//   リスナーを持たないセルの行だけに使う)。

const renderedHtml = new WeakMap();

function syncAttributes(target, source) {
  for (const attr of [...target.attributes]) {
    if (!source.hasAttribute(attr.name)) {
      target.removeAttribute(attr.name);
    }
  }
  for (const attr of [...source.attributes]) {
    if (target.getAttribute(attr.name) !== attr.value) {
      target.setAttribute(attr.name, attr.value);
    }
  }
}

/** el と直下の子の挿入時点の outerHTML を控える(recurseWhen で1段降りたとき、変わっていない子を残すため) */
function markRendered(el) {
  renderedHtml.set(el, el.outerHTML);
  for (const child of el.children) {
    renderedHtml.set(child, child.outerHTML);
  }
}

/** container の子を nextChildren(未挿入の新しい要素)へ揃える。同じ位置の古い子が前回挿入した時点と
 *  同じ outerHTML なら古い子を残す。 */
export function syncChildren(container, nextChildren, options = {}) {
  const { recurseWhen } = options;
  const current = [...container.children];
  nextChildren.forEach((next, i) => {
    const old = current[i];
    const html = next.outerHTML;
    if (!old) {
      markRendered(next);
      container.appendChild(next);
      return;
    }
    if (renderedHtml.get(old) === html) {
      return;
    }
    // 降りるのは1段だけ(行 → セル)。子は要素だけで組まれていること(テキストノードを直に持たない = tr)
    if (recurseWhen && old.tagName === next.tagName && next.childNodes.length === next.children.length
        && recurseWhen(old, next)) {
      syncAttributes(old, next);
      syncChildren(old, [...next.children]);
      renderedHtml.set(old, html);
      return;
    }
    markRendered(next);
    container.replaceChild(next, old);
  });
  for (const extra of current.slice(nextChildren.length)) {
    extra.remove();
  }
}
