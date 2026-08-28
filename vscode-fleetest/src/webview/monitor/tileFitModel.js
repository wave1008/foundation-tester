// デバイスタブ auto-fit の高さ計算(DOM 非依存。実測は splitter.js が行う)。
//
// 前提(style.css): .grid は flex-wrap:nowrap の1行・横スクロール、画像の幅は
// 「--tile-image-h × --tile-aspect」で決まる。タイル幅はそれに padding/border を足したもの
// ——ただし**画像以外の子がもっと広い幅を要求していれば、そちらがタイル幅を決める**
// (マシン名バッジの段など)。この床(floorWidth)を無視して「画像以外は定数」と置くと、
// 床のぶんを毎回タイルの固定費として引いてしまい、台数が多いほど画像が不当に潰れる。
// padding/border/gap の定数は持たない(全て実測値で渡ってくる)。

// 端数の切り上げで横スクロールバーが出るのを防ぐ余白(px)。
export const FIT_SLACK_PX = 1;

// auto-fit がこれ以上小さくしない画像の高さ(px)。下回るなら1行に詰めるのをやめ、
// 溢れたぶんは横スクロールに任せる(ユーザー決定 2026-08-28「下限を設けて横スクロール」)。
// 根拠: CSS 既定の --tile-image-h(240px)の半分 —— 縦持ちで幅 55px 前後になり、
// 「何のアプリの画面か・縦か横か・真っ黒でないか」がまだ判別できる下限。ここを下回ると
// 22 台のような構成で全タイルが数十 px まで潰れ、フリートとして読めない。
// 尽きたとき(下限でも1行に収まらない)は縮めるのではなく横スクロールへ倒す。
export const MIN_FIT_IMAGE_HEIGHT_PX = 120;

// 二分探索の停止幅(px)。返り値は Math.floor するので 1px 未満まで詰めれば十分。
const FIT_SEARCH_EPSILON_PX = 0.25;
// 二分探索の回数の上限。**停止条件を幅だけに任せない** —— 幅が h で増えない入力を掴むと
// 収束せず、webview の main thread ごと固まる(範囲は毎回半分になるので 60 回で十分)。
const FIT_SEARCH_MAX_STEPS = 60;

function isMeasured(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

/**
 * 画像高さ h のときのタイル合計幅(gap 込み)。
 * @param {number} h 画像の高さ(px)
 */
function totalWidthAt(h, tiles, aspectBase, gap) {
  let total = gap * (tiles.length - 1);
  for (const tile of tiles) {
    // 画像以外が要求する床より狭くはならない(タイル幅は max を取る)。
    total += tile.chromeWidth + Math.max(tile.floorWidth || 0, (tile.imageWidth / aspectBase) * h);
  }
  return total;
}

/**
 * @param {{paneOverhead:number, imageHeight:number, gridWidth:number, gap:number,
 *          minImageHeight?:number,
 *          tiles:ReadonlyArray<{imageWidth:number, chromeWidth:number, floorWidth?:number}>}} m 実測値。
 *   paneOverhead はペイン高さのうち画像以外(**下限クランプ前**の対応で測ること。クランプに
 *   張り付いた高さから引くと、返した高さで画像が下端に隠れる)。imageHeight は tiles の
 *   imageWidth を測ったときの画像高さ、chromeWidth はタイル幅のうち padding+border、
 *   floorWidth は画像以外の子が要求している幅(通常 0)。
 * @returns {number|null} 収まる高さ(px)。測れない(タイル無し・レイアウト未確定)ときは null で、
 *   呼び出し側は高さを変えない。下限でも収まらないときは下限の高さ(=横スクロールに任せる)。
 */
export function computeFitPaneHeight(m) {
  if (!m || !Array.isArray(m.tiles) || m.tiles.length === 0) {
    return null;
  }
  if (!isMeasured(m.paneOverhead) || !(m.imageHeight > 0) || !(m.gridWidth > 0)) {
    return null;
  }
  for (const tile of m.tiles) {
    if (!(tile.imageWidth > 0) || !(tile.chromeWidth >= 0)) {
      return null;
    }
    if (tile.floorWidth !== undefined && !(tile.floorWidth >= 0)) {
      return null;
    }
  }
  const gap = m.gap > 0 ? m.gap : 0;
  const minImageHeight = m.minImageHeight > 0 ? m.minImageHeight : MIN_FIT_IMAGE_HEIGHT_PX;
  const limit = m.gridWidth - FIT_SLACK_PX;
  const total = (h) => totalWidthAt(h, m.tiles, m.imageHeight, gap);
  // 画像の高さ 1px あたりの幅(いちばん横に長いタイル)。上端の算出に使う。
  const maxImageRatio = Math.max(...m.tiles.map((tile) => tile.imageWidth / m.imageHeight));
  if (!(maxImageRatio > 0)) {
    return null;
  }
  // 二分探索(合計幅は h に対して単調増加)。閉じた式にしないのは、床に張り付いている
  // タイルとそうでないタイルが混ざると区分線形になるため。
  // 下端は下限そのもの —— 下限でも収まらない台数のときはここが答えになり、溢れたぶんは
  // 横スクロールで見る(縮めない)。上端は「いちばん横に長いタイル1枚だけで幅を使い切る
  // 高さ」で、合計幅はどのタイル単独の幅より必ず大きいので、これを超える h は収まらない。
  let lo = minImageHeight;
  let hi = Math.max(lo, limit / maxImageRatio);
  for (let step = 0; step < FIT_SEARCH_MAX_STEPS && hi - lo > FIT_SEARCH_EPSILON_PX; step++) {
    const mid = (lo + hi) / 2;
    if (total(mid) <= limit) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return Math.floor(m.paneOverhead + lo);
}
