// 「軌跡モード」(ライブ操作の1本指ドラッグを、離さない1本のタッチとして再生する)の点列の
// 間引き(純粋関数。DOM に触らない)。
//
// pointermove は環境によって数ms〜十数msごとに発火し、長い/速いドラッグでは数百〜千点を超えうる。
// そのまま送ると ft_gesture / GestureRequest の1指あたりの点数上限(TouchGesture.maxPointsPerFinger
// = 625)に触れる。2段で間引く:
//   ①直前に残した点から16ms未満の点は捨てる(間隔を敷き直すだけで軌跡の形はほぼ変えない)
//   ②それでも600点を超えていれば均等間引きで600点にする(形が単調に崩れる。①で足りない
//     極端に長い/密なドラッグだけがここに落ちる)
// **どちらの段も先頭・末尾は必ず残す**(始点・終点を欠くとタップ開始位置やリフト位置がずれる)。

const MIN_KEPT_INTERVAL_MS = 16;
const MAX_POINTS = 600;

/**
 * points: [{x, y, t}, ...]。t は先頭を0とする昇順のミリ秒。空・1点はそのまま返す。
 * 間引き後も t の昇順は保たれる(元の配列が昇順である前提)。
 */
export function thinTracePoints(points) {
  if (points.length <= 2) {
    return points;
  }
  const byInterval = [points[0]];
  let lastKeptT = points[0].t;
  for (let i = 1; i < points.length - 1; i++) {
    const p = points[i];
    if (p.t - lastKeptT >= MIN_KEPT_INTERVAL_MS) {
      byInterval.push(p);
      lastKeptT = p.t;
    }
  }
  byInterval.push(points[points.length - 1]);
  if (byInterval.length <= MAX_POINTS) {
    return byInterval;
  }
  const thinned = [];
  const step = (byInterval.length - 1) / (MAX_POINTS - 1);
  for (let i = 0; i < MAX_POINTS; i++) {
    thinned.push(byInterval[Math.round(i * step)]);
  }
  return thinned;
}
