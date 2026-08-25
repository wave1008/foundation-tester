// 選択したデバイスの拡大表示を「1台ぶんの絵が一番大きくなる」段組みで並べるための計算
// (DOM 非依存。実測は laneLog.js が行う)。
//
// 前提(style.css): #lanes-grid は grid で、列も行も 1fr の等分。1セル = タグ段 + 絵の枠で、
// 絵は縦横比を保ったまま枠に収まる(max-width/max-height)。よって絵の大きさは
// min(セル高 - タグ段, セル幅 / 縦横比) で決まり、これが最大になる列数を選べばよい。
// padding/gap/タグ段の定数は持たない(全て実測値で渡ってくる)。

// 同点とみなす幅(px)。同点のときは **段数の少ない方 → 列数の少ない方** の順に採る:
// 段が少ない = 「2台なら左右」の見た目(ユーザー要件 2026-08-24)。同じ段数なら列が少ない方が
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
