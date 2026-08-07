# 実アプリのスナップショット(検知の回帰用フィクスチャ)

`GET /snapshot` の生 JSON をそのまま置いてある。**自前の 4 SUT は遮蔽・積み重なり・
中身外しの形を代表しない**(2026-08-07 の3ラウンドで、誤検知も真陽性も実アプリでだけ出た)ので、
`SweepHarnessTests` はここへ全数で検知を当てて件数を基準値と突き合わせる。

| 接頭辞 | 由来 | 何を代表するか |
|---|---|---|
| `and-` | Google マップ 11.x / Android 15(emulator) | 塗り順 `z` を**持つ**木・全画面シート・横カルーセル。`and-maps_suggest_ime` は IME を開いたまま採った木(`keyboardFrame` 申告付き。ブリッジ版53以降でだけ採れる) |
| `ios-` | Apple マップ / iOS 27.0(Simulator・xcuitest) | `z` を**持たない**木(ツリー順フォールバック)。`ios-maps_suggest_keyboard`(キーボード + `keyboardFrame`)と `ios-maps_station`(地図 POI 67個 = bulk 間引き後の高密度画面)は 2026-08-08・版58 で採取 |
| `sut-` | E2E-CMP(自前) | `disabled` の供給源(実アプリのコーパスには1件も無い) |
| `sutec-` | sut-ec-mobile / iOS 27.0(Simulator・**in-app**) | in-app エンジンの木(それまで1枚も無かった)・画面外中心(`offscreen`)の供給源・下部バーの遮蔽 |

**採り直すとき**は基準値も一緒に更新する(`SweepHarnessTests.baselines`)。件数が増えたら
まず誤検知を疑い、真陽性だと確かめてから基準値を上げること —— 黙って上げると、
この砦は「現状を追認するだけ」になる。

内容は公開アプリの UI ラベル(店名・広告見出しを含む)。個人データは含まない。
