// デバイスタブ auto-fit の高さ計算(DOM 非依存。実測は splitter.js が行う)。
//
// 前提(style.css): .grid は flex-wrap:nowrap の1行・横スクロール、タイル幅は
// 「--tile-image-h × --tile-aspect」に比例する。画像高さ→タイル高さ→タイルペイン高さは
// 定数差でしかないので、画像高さの増減分をそのままペイン高さへ足せる。
// padding/border/gap の定数は持たない(全て実測値で渡ってくる)。

// 端数の切り上げで横スクロールバーが出るのを防ぐ余白(px)。
export const FIT_SLACK_PX = 1;

/**
 * @param {{paneHeight:number, imageHeight:number, gridWidth:number, gap:number,
 *          tiles:ReadonlyArray<{imageWidth:number, chromeWidth:number}>}} m 実測値。
 *   imageHeight は現在の --tile-image-h、chromeWidth はタイル幅のうち画像以外(padding+border)。
 * @returns {number|null} 収まる高さ(px)。測れない(タイル無し・レイアウト未確定・幅が
 *   足りない)ときは null で、呼び出し側は高さを変えない。
 */
export function computeFitPaneHeight(m) {
  if (!m || !Array.isArray(m.tiles) || m.tiles.length === 0) {
    return null;
  }
  if (!(m.paneHeight > 0) || !(m.imageHeight > 0) || !(m.gridWidth > 0)) {
    return null;
  }
  let imageWidthSum = 0;
  let chromeWidthSum = 0;
  for (const tile of m.tiles) {
    // 選択中タイルは border 2px/padding 7px と内訳が違うため chromeWidth はタイルごとに来る。
    if (!(tile.imageWidth > 0) || !(tile.chromeWidth >= 0)) {
      return null;
    }
    imageWidthSum += tile.imageWidth;
    chromeWidthSum += tile.chromeWidth;
  }
  const gap = m.gap > 0 ? m.gap : 0;
  const availableImageWidth =
    m.gridWidth - chromeWidthSum - gap * (m.tiles.length - 1) - FIT_SLACK_PX;
  if (!(availableImageWidth > 0)) {
    return null;
  }
  const fitImageHeight = m.imageHeight * (availableImageWidth / imageWidthSum);
  return Math.floor(m.paneHeight + (fitImageHeight - m.imageHeight));
}
