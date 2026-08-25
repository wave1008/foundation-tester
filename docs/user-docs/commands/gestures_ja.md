# gestures (doubleTap, pinchOut, pinchIn)

マルチタッチのジェスチャです: ダブルタップ、拡大のためのピンチアウト、縮小のためのピンチイン。

## 関数

| 関数 | 説明 |
|---|---|
| `doubleTap(sel?)` | ダブルタップします。セレクタ省略時は画面中心をタップします。`tap` を2回書いても代用にはなりません —— 往復で OS のダブルタップ判定時間を超えてしまいます。 |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5)` | 2本指を開きます = 拡大。`scale` は 1 より大きい値のみ指定できます。 |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5)` | 2本指を閉じます = 縮小。`scale` は 0 より大きく 1 未満の値のみ指定できます。 |

これらとよく組み合わせるパンのジェスチャ `swipeBy(sel?, dxRatio:dyRatio:durationSeconds:)` は
[swipe](./swipe_ja.md) を参照してください。

## 例

```swift
doubleTap("#photo")
pinchOut("#map", scale: 2.5)
pinchIn("#map", scale: 0.4)
swipeBy("#map", dxRatio: -0.3, dyRatio: 0.0)   // 左へパン
```

## マップ・キャンバス系の画面

地図・画像ビューア・図面のような画面は、次の4つで操作します: `swipeBy` でパン(斜め含む)・
`pinchOut`/`pinchIn` でズーム・`doubleTap` でズームイン。注意点は3つあります:

- **ピンチの対象指定は経路で仕組みが違います。** Android と iOS の in-app は指定領域の中心で
  2本指を合成しますが、**iOS の XCUITest は座標指定の多点ジェスチャを持たない**ため、
  `accessibilityIdentifier` で要素を引いてピンチします。**id の無い要素を XCUITest 経路で
  指定すると画面全体のピンチに落ち**、ステップに注記が残ります。
- **iOS はエンジンによって成否が分かれるジェスチャがあります。** 既定の hybrid エンジンなら
  全フレームワークで動きます(ホストが自動で使い分けます)。Android にはこの区別が無く、
  全ジェスチャがどこでも動きます:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter |
  |---|---|---|---|
  | `swipeBy`(斜め含む) | ✅ | ✅ | ✅ |
  | `doubleTap` | ✅ XCUITest | ✅ **in-app のみ** | ✅ |
  | `pinchOut` / `pinchIn` | ✅ XCUITest | ✅ | ✅ **in-app のみ** |

  「in-app のみ」は、`xcuitest` 単独プロファイルや物理端末では効かないという意味です
  (物理端末は注入不可のため XCUITest しか経路がありません)。MCP の `ft_*` ツールも
  `profile` を渡せば同じエンジンで動きます。
- **指定した倍率どおりに出るとは限りません。** 2本指はピンチしている領域の外へは置けないため、
  極端な `scale` を指定してもその領域で出せる最大値で頭打ちになります。**倍率そのものより
  「拡大/縮小が起きたこと」を検証する**方が、アプリを跨いで安定します。

### Link
- [index](../index_ja.md)
