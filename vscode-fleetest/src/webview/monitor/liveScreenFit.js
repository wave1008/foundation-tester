// 「ライブ操作」タブの画面表示サイズの計算(純粋関数。DOM に触らない)。
//
// **絵の解像度で決めてはいけない**のがこのモジュールの理由: 同じ画面を映す供給元が2つあり
// (配信 = fleetest-simstream の長辺 900px、snapshot = ブリッジの原寸)、さらに配信の IOSurface は
// システムダイアログの表示などで寸法が変わる(fleetest-simstream/main.m の「IOSurfaceサイズ変化で
// Invalidate」参照)。解像度で決めると、同じ画面なのに表示サイズが動く(2026-09-21 の実害:
// システムダイアログが出ると画像が小さくなる)。デバイスの画面比は不変なのでそれで決める。

/** 表示に使う縦横比(w/h)。screen(デバイスの画面サイズ。不変)を最優先し、まだ無いときだけ
 * 絵の自然サイズに落ちる。どちらも無ければ null(呼び出し側は幅の指定を外す)。 */
export function displayAspect(screen, natural) {
  if (screen && screen.width > 0 && screen.height > 0) {
    return screen.width / screen.height;
  }
  if (natural && natural.w > 0 && natural.h > 0) {
    return natural.w / natural.h;
  }
  return null;
}

/**
 * **pane の幅**を決めるための表示寸法[px]。高さは pane の残り(maxH)いっぱいまで使い、
 * 手動幅(スプリッター)があるときだけ幅で頭打ちにする。
 *
 * **絵そのものの寸法には使わない** —— 絵に幅・高さを入れると、screen が実画面と食い違った回に
 * その比へ引き伸ばされる(実害 2026-09-22)。絵は max-width/max-height だけで収め、縦横比は
 * 絵に決めさせる。ここで決めるのは「右の要素一覧をどこから並べるか」だけ。
 * aspect が null のときは null(呼び出し側は幅の指定を外す)。
 */
export function fitScreenSize(aspect, maxH, widthCap) {
  if (aspect === null || !(maxH > 0)) {
    return null;
  }
  const cap = typeof widthCap === "number" && widthCap > 0 ? widthCap : Infinity;
  const height = Math.min(maxH, cap / aspect);
  return { width: height * aspect, height };
}
