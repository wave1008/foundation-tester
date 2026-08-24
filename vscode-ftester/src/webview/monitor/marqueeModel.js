// 範囲選択(フリートをドラッグして矩形で選ぶ)の幾何。DOM 非依存で、座標は viewport の px。
// 実測(getBoundingClientRect)と選択状態の書き換えは deviceTiles.js が行う。

// ここまでの動きは「クリック」として扱う(px)。タイルのクリック(選択トグル)が手ぶれで
// 矩形選択へ化けるのを防ぐ下限。マウスのクリック時のブレは数 px なのでそれを超える値。
export const DRAG_THRESHOLD_PX = 4;

export function isDragDistance(dx, dy) {
  return Math.abs(dx) >= DRAG_THRESHOLD_PX || Math.abs(dy) >= DRAG_THRESHOLD_PX;
}

/** 開始点と現在点から矩形を作る(どちらの向きへドラッグしても正の幅・高さ)。 */
export function marqueeRect(origin, point) {
  return {
    left: Math.min(origin.x, point.x),
    top: Math.min(origin.y, point.y),
    width: Math.abs(point.x - origin.x),
    height: Math.abs(point.y - origin.y),
  };
}

// 辺が触れるだけ(重なりの幅・高さが 0)は「重なった」に数えない。数えると、ほとんど
// 動かしていないドラッグが真下のタイルを掴んでクリックとの区別が付かなくなる。
export function rectsOverlap(a, b) {
  return a.left < b.left + b.width
    && b.left < a.left + a.width
    && a.top < b.top + b.height
    && b.top < a.top + a.height;
}

/** 点が矩形の中(縁を含む)か。クリックの当たり判定に使う。 */
export function rectContains(rect, point) {
  return point.x >= rect.left && point.x <= rect.left + rect.width
    && point.y >= rect.top && point.y <= rect.top + rect.height;
}

/**
 * 矩形選択の結果。Ctrl/Cmd を押している間は前の選択を残して足す(押していなければ置き換え)。
 * base を先に並べるので、既に選ばれていた台の順序は変わらない。
 * @param {ReadonlyArray<string>} baseIds ドラッグを始めた時点の選択
 * @param {ReadonlyArray<string>} hitIds 矩形と重なった id
 * @param {boolean} additive Ctrl/Cmd を押しているか
 * @returns {string[]} 重複を除いた選択
 */
export function mergeMarqueeSelection(baseIds, hitIds, additive) {
  if (!additive) {
    return [...hitIds];
  }
  const merged = [...baseIds];
  for (const id of hitIds) {
    if (!merged.includes(id)) {
      merged.push(id);
    }
  }
  return merged;
}

/**
 * @param {{left:number, top:number, width:number, height:number}} rect 矩形(viewport)
 * @param {ReadonlyArray<{id:string, rect:{left:number, top:number, width:number, height:number}}>} items
 * @returns {string[]} 矩形と重なった id(items の順序を保つ)
 */
export function idsInMarquee(rect, items) {
  const ids = [];
  for (const item of items) {
    if (rectsOverlap(rect, item.rect)) {
      ids.push(item.id);
    }
  }
  return ids;
}
