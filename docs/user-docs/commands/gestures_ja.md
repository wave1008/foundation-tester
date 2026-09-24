# gestures (doubleTap, pinchOut, pinchIn)

マルチタッチのジェスチャです: ダブルタップ、拡大のためのピンチアウト、縮小のためのピンチイン。

## 関数

| 関数 | 説明 |
|---|---|
| `doubleTap(sel?)` | ダブルタップします。セレクタ省略時は画面中心をタップします。`tap` を2回書いても代用にはなりません —— 往復で OS のダブルタップ判定時間を超えてしまいます。 |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5, maxGestureSeconds:)` | 2本指を開きます = 拡大。`scale` は 1 より大きい値のみ指定できます。`durationSeconds` の上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます。 |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5, maxGestureSeconds:)` | 2本指を閉じます = 縮小。`scale` は 0 より大きく 1 未満の値のみ指定できます。上限は `pinchOut` と同じです。 |

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

- **ピンチはどの経路でも「領域」で狙います。** Android と iOS の in-app は指定領域の中心で
  2本指を合成し、iOS の XCUITest は領域の向かい合う2点に指を置きます。領域が使えないときだけ
  XCUITest が `accessibilityIdentifier` で要素を引いてピンチし、そのことがステップの注記に残ります。
- **対象を書かない `pinchOut()` / `pinchIn()` は画面中央の狭い範囲に効きます**
  (画面全体ではありません)。**指の2点が別々のものに載るとピンチになりません** ——
  Apple マップでの実測(2026-09-22)では、画面全体でピンチすると下の指が検索カードに乗り、
  **縮小が地図のパンに化けました**(拡大は指が中央から開くので効く、という非対称がありました)。
  そこで**両方の指が同じものに載る位置**を選んで撃ちます。置けなければ半径を狭め、
  それでも駄目なときだけ従来どおり画面全体でピンチします。
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
