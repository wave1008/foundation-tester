// FM/OCR スパークラインの縦軸の目盛り。**DOM に触らない**ので単体で import できる
// (hostCharts.js は読み込み時に document を引くため、テストから直接は読めない)。

/** FM スパークラインの縦軸の上限(1 tick あたりの呼び出し回数)。読みやすさのための**固定目盛り**で、
 *  物理的な上限ではない。**FMLock の既定の枠数に合わせてある**が、根拠は次のとおり:
 *
 *  **枠は「同時に走れる本数」であって「1秒あたりの回数」ではない。** 1 tick に完了する回数は
 *  概ね 枠 ÷ レイテンシで、FM 1回は実測 1.4〜2.1 秒(2026-09-02・E2E-CMP 4レーン)なので
 *  門を通る run では結果的に枠数を下回る。**レイテンシが1秒を切れば枠数を超える**し、
 *  門を通らない `doctor --fm-load` は無関係に超える —— どちらも天井で頭打ちになる。
 *
 *  つまりこの値は「まず超えない目安」であって保証ではない。だから**下限**として使い、
 *  超えた窓ではオートスケールする(`hmCountScale`)。枠数の既定を動かすときは目盛りも見直す
 *  (`hostChartsFmMaxSync.test.mjs` がズレを検出する)。
 *  同期相手: Sources/FTCore/FMLock.swift の defaultConcurrency */
export const HM_FM_MAX_RATE = 5;

/** OCR スパークラインの縦軸の上限(1 tick あたりの呼び出し回数)。**根拠は FM とは別**:
 *  occlusion-guard の1ステップは、読めなければ crop を拡大して読み直す
 *  (`RegionText.upscaleLadder`)ので最大 `upscaleLadder.count`(= 3)回まで OCR を撃つ。
 *  1 tick に1ステップぶん撃っただけで振り切れない高さが下限として要る。
 *  超えた窓ではオートスケールする(`hmCountScale`。FM と同じ下限付きスケールの考え方)。
 *  段数を動かしたら目盛りも見直す(`hostChartsOcrMaxSync.test.mjs` がズレを検出する)。
 *  同期相手: Sources/FTCore/RegionText.swift の upscaleLadder */
export const HM_OCR_MAX_RATE = 3;

/** 件数系列(FM/OCR)の縦軸の上限。**floor を下回らせない**のが要点 ——
 *  純粋なオートスケールだと、0〜1回しか出ていない窓でも最大値まで引き伸ばされ、
 *  「たまに1回」が「振り切れている」ように描かれる(行同士も時刻同士も比べられない)。
 *  一方で上限に固定すると、それを超える負荷(門を通らない `doctor --fm-load` や、
 *  レイテンシが1秒を切ったとき)が天井で潰れて変化が読めない。
 *  欠測(null)は無視する。全欠測・空なら floor をそのまま返す。
 *  **floor に既定値を置かない** —— FM と OCR は別の量で下限も別なので、既定を置くと
 *  呼び忘れが静かに片方の下限へ落ち、もう片方が別の目盛りで描かれていることに気付けない。 */
export function hmCountScale(samples, floor) {
  const known = samples.filter((v) => v !== null && v !== undefined);
  return Math.max(floor, ...known);
}

/** 全行ぶんのサンプル(配列の配列)を1つの縦軸にまとめる。
 *  **行ごとに別々のスケールを取らない** —— 機械を並べて比べるのが件数系列の行の目的なので、
 *  行ごとに伸縮すると「2回/秒の機械」と「8回/秒の機械」が同じ高さに描かれ、
 *  グラフが並んでいる意味が消える。floor は hmCountScale と同じ(既定値を置かない)。 */
export function hmSharedCountScale(perRowSamples, floor) {
  return hmCountScale(perRowSamples.flat(), floor);
}
