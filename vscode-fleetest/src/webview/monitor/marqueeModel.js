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

// ---- ドラッグ中に端へ寄せている間の自動スクロール(横だけ。グリッドは overflow-y:hidden) ----

// 端の帯の幅(px)。ポインタがこの中に居る間だけ流れる。
// 下限の根拠: DRAG_THRESHOLD_PX(4px = クリックのブレ)より十分広く「意図して端へ寄せた」と
// 言えること。上限の根拠: 最小のタイル幅(既定の画像高 240px × アスペクト 0.46 ≒ 110px)より
// 狭いこと —— 広いと端に映っているタイルを狙って止めていられない。
export const AUTO_SCROLL_EDGE_PX = 40;

// 表示幅が狭いときに帯を縮める割合。左右の帯が触れ合うとどこへ置いても流れる = 止められない
// ので、片側は表示幅の 1/4 までにする(表示幅 160px 未満で効き始める)。
export const AUTO_SCROLL_EDGE_MAX_RATIO = 0.25;

// 帯の最奥(表示の端、またはその外)での速さ。単位は「表示幅/秒」 —— px/秒で持つと狭い
// パネルでは速すぎ広いパネルでは遅すぎる(体感は画面何枚ぶん流れたかで決まる)。内容幅では
// なく表示幅で決めるので、フリートが何台でも同じ体感になる。
export const AUTO_SCROLL_MAX_VIEWS_PER_SEC = 1.2;

// 1回の刻みで進める時間の上限(ms)。フリートは配信の描画と同じ main thread に載っており、
// 詰まると rAF が数百 ms 飛ぶ。飛んだぶんをそのまま送ると指を止めているのに何画面も流れる
// ので頭打ちにする(尽きたときは速く流れるのではなく、詰まっている間だけ進みが遅れる)。
export const AUTO_SCROLL_MAX_STEP_MS = 100;

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

/** 端の帯の幅(表示幅が狭いときは縮める)。 */
export function autoScrollEdgeWidth(viewWidth) {
  return Math.min(AUTO_SCROLL_EDGE_PX, Math.max(0, viewWidth) * AUTO_SCROLL_EDGE_MAX_RATIO);
}

/**
 * 端への寄り具合から横スクロールの速さを出す。帯の入口で 0、端(およびその外)で最大の線形。
 * @param {number} x ポインタの viewport x
 * @param {number} viewLeft 表示領域の左端(viewport)
 * @param {number} viewWidth 表示領域の幅
 * @returns {number} px/秒。右へ流すとき正・左へ流すとき負・帯の外は 0
 */
export function autoScrollVelocity(x, viewLeft, viewWidth) {
  const edge = autoScrollEdgeWidth(viewWidth);
  if (edge <= 0) {
    return 0;
  }
  const max = viewWidth * AUTO_SCROLL_MAX_VIEWS_PER_SEC;
  const fromLeft = x - viewLeft;
  if (fromLeft < edge) {
    return -max * clamp01((edge - fromLeft) / edge);
  }
  const fromRight = viewLeft + viewWidth - x;
  if (fromRight < edge) {
    return max * clamp01((edge - fromRight) / edge);
  }
  return 0;
}

/** 速さと経過時間から1回ぶんの移動量(px)。dt は AUTO_SCROLL_MAX_STEP_MS で頭打ち。 */
export function autoScrollStep(velocity, dtMs) {
  const dt = Math.min(Math.max(dtMs, 0), AUTO_SCROLL_MAX_STEP_MS);
  return velocity * dt / 1000;
}
