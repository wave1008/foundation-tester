// 「デバイスモニター」タブの縦分割の可動域(純粋関数。DOM に触らないので単体テストで固める)。
// 呼び手は splitter.js で、各値は実測(offsetHeight / padding)を渡す。
//
// 縦の並び: ツールバー・run ボード・ラインビューの見出し → tile-pane → splitter →
// log-pane → splitter-log → output-pane。**セパレーターをどこまで動かしても
// 実行ログビュー・グリッドビューの見出し行は消さない**(ユーザー決定 2026-09-21)。

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
