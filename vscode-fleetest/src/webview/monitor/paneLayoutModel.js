// 「デバイスモニター」タブの縦分割の可動域(純粋関数。DOM に触らないので単体テストで固める)。
// 呼び手は splitter.js で、各値は実測(offsetHeight / padding)を渡す。
//
// 縦の並び: ツールバー → run ボード → devices-separator → ラインビューの見出し → tile-pane →
// splitter → output-pane → splitter-log → log-pane。**セパレーターをどこまで動かしても
// run ボード・実行ログビュー・グリッドビューの見出し行は消さない**(ユーザー決定 2026-09-21)。

export function clampHeight(value, min, max) {
  return Math.min(Math.max(value, min), Math.max(min, max));
}

/** ラインビュー(tile-pane)の可動域。bottomChrome = 下2ペインが見出し行だけになったときの合計高さ。 */
export function tilePaneLimits({ available, bottomChrome, minTile }) {
  return { min: minTile, max: Math.max(minTile, available - bottomChrome) };
}

/** 実行ログビュー(log-pane)の可動域。下限は自分の見出し行・上限はグリッドビューの見出し行を残す位置。 */
export function logPaneLimits({ bottomAvailable, logChrome, gridChrome }) {
  return { min: logChrome, max: Math.max(logChrome, bottomAvailable - gridChrome) };
}

/** run ボード(#run-board)の可動域。下限は自分の見出し行・上限は3ペインの最小を残す位置。
 *  available = run ボードと3ペインが分け合う高さ・panesMin = 3ペインが取る最小の合計。 */
export function runBoardLimits({ available, headerHeight, panesMin }) {
  return { min: headerHeight, max: Math.max(headerHeight, available - panesMin) };
}
