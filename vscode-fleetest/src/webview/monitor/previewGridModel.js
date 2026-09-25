// 選択したデバイスの拡大表示を「1台ぶんの絵が一番大きくなる」段組みで並べるための計算
// (DOM 非依存。実測は laneLog.js が行う)。
//
// 前提(style.css): #lanes-grid は grid で、列も行も 1fr の等分。1セル = タグ段 + 絵の枠で、
// 絵は縦横比を保ったまま枠に収まる(max-width/max-height)。よって絵の大きさは
// min(セル高 - タグ段, セル幅 / 縦横比) で決まり、これが最大になる列数を選べばよい。
// padding/gap/タグ段の定数は持たない(全て実測値で渡ってくる)。

// 同点とみなす幅(px)。同点のときは **段数の少ない方 → 列数の少ない方** の順に採る:
// 段が少ない = 「2台なら左右」の見た目(ユーザー要件)。同じ段数なら列が少ない方が
// 1台あたりの枠が広く、端の列だけ空く歪な形(6台を5列2段など)にならない。
const TIE_PX = 0.5;

/**
 * @param {{paneWidth:number, paneHeight:number, count:number, aspect:number,
 *          gap:number, chromeHeight:number}} m 実測値。
 *   aspect は絵の 幅/高さ(選択した台のうち一番横に広いもの)、chromeHeight は
 *   1セルのうち絵以外(タグ段+その下の間隔)の高さ。
 * @returns {{columns:number, rows:number}} 段組み。測れない(タブ非表示・初回描画前)
 *   ときは従来どおりの横一列を返す —— 次の再計算で本来の形になる。
 */
export function computePreviewGrid(m) {
  const count = m && m.count > 0 ? Math.floor(m.count) : 0;
  if (count <= 0) {
    return { columns: 1, rows: 1 };
  }
  if (!(m.paneWidth > 0) || !(m.paneHeight > 0) || !(m.aspect > 0)) {
    return { columns: count, rows: 1 };
  }
  const gap = m.gap > 0 ? m.gap : 0;
  const chromeHeight = m.chromeHeight > 0 ? m.chromeHeight : 0;
  const candidates = [];
  for (let columns = 1; columns <= count; columns++) {
    const rows = Math.ceil(count / columns);
    const cellWidth = (m.paneWidth - gap * (columns - 1)) / columns;
    const cellHeight = (m.paneHeight - gap * (rows - 1)) / rows - chromeHeight;
    candidates.push({ columns, rows, imageHeight: Math.min(cellHeight, cellWidth / m.aspect) });
  }
  // 最大から TIE_PX 以内は同点。「近い方を順に上書き」だと同点判定が連鎖して最大から
  // 離れていくので、最大を先に決めてから同点の中で選ぶ。
  const bestHeight = Math.max(...candidates.map((c) => c.imageHeight));
  const tied = candidates.filter((c) => c.imageHeight > bestHeight - TIE_PX);
  tied.sort((a, b) => (a.rows - b.rows) || (a.columns - b.columns));
  return { columns: tied[0].columns, rows: tied[0].rows };
}

// 1台だけ選択したとき(左 = 拡大表示・右 = 実行ログ)の拡大表示の外寸幅(px)。
// 絵の高さはペインの高さで決まる(1行)ので、幅 = 絵の高さ × 縦横比 + 枠の横方向の固定費。
// ログの幅を残すため maxRatio(ペイン幅に対する比)で頭打ちにする。縦横比が未確定(フレーム未着)の間は
// 頭打ちの幅で置き、確定後の再計算で締める。測れないときは null(呼び手は幅を指定しない)。
export const SINGLE_PREVIEW_MAX_RATIO = 0.6;

/**
 * @param {{paneWidth:number, paneHeight:number, aspect:number, chromeHeight:number,
 *          chromeWidth:number}} m 実測値。chromeHeight/chromeWidth は拡大表示の外寸のうち
 *   絵の枠以外(タグ段・余白・枠線)の高さ/幅。
 * @returns {number|null}
 */
export function computeSinglePreviewWidth(m) {
  if (!m || !(m.paneWidth > 0) || !(m.paneHeight > 0)) {
    return null;
  }
  const cap = Math.floor(m.paneWidth * SINGLE_PREVIEW_MAX_RATIO);
  if (!(m.aspect > 0)) {
    return cap;
  }
  const imageHeight = Math.max(0, m.paneHeight - (m.chromeHeight > 0 ? m.chromeHeight : 0));
  const width = Math.ceil(imageHeight * m.aspect + (m.chromeWidth > 0 ? m.chromeWidth : 0));
  return Math.min(width, cap);
}
