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
 * 画像の表示寸法[px]。高さは pane の残り(maxH)いっぱいまで使い、手動幅(スプリッター)が
 * あるときだけ幅で頭打ちにする。**幅と高さの両方を返す**のは、片方だけ指定して max-width に
 * もう片方を任せると、幅で制限されたときに縦横比が崩れるため。
 * aspect が null のときは null(呼び出し側は従来どおり絵に任せる)。
 */
export function fitScreenSize(aspect, maxH, widthCap) {
  if (aspect === null || !(maxH > 0)) {
    return null;
  }
  const cap = typeof widthCap === "number" && widthCap > 0 ? widthCap : Infinity;
  const height = Math.min(maxH, cap / aspect);
  return { width: height * aspect, height };
}
