# gestures (doubleTap, pinchOut, pinchIn, gesture)

マルチタッチのジェスチャです: ダブルタップ、拡大のためのピンチアウト、縮小のためのピンチイン、
そしてこの3つで表せない動きを組む生のジェスチャビルダー。

## 関数

| 関数 | 説明 |
|---|---|
| `doubleTap(sel?)` | ダブルタップします。セレクタ省略時は画面中心をタップします。`tap` を2回書いても代用にはなりません —— 往復で OS のダブルタップ判定時間を超えてしまいます。 |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5, maxGestureSeconds:)` | 2本指を開きます = 拡大。`scale` は 1 より大きい値のみ指定できます。`durationSeconds` の上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます。 |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5, maxGestureSeconds:)` | 2本指を閉じます = 縮小。`scale` は 0 より大きく 1 未満の値のみ指定できます。上限は `pinchOut` と同じです。 |
| `gesture(sel?, maxGestureSeconds:waitSeconds:) { FTFinger(x:y:).move(x:y:durationSeconds:).hold(seconds:) }` | 指1本以上の経路を、離さない1本のタッチ列として再生します —— パターンロック・長押しからのドラッグ・2本指回転など、`pinchOut`/`pinchIn`/`doubleTap`/`swipeBy` で表せない動き用です。 |

これらとよく組み合わせるパンのジェスチャ `swipeBy(sel?, dxRatio:dyRatio:durationSeconds:)` は
[swipe](./swipe_ja.md) を参照してください。

## 例

```swift
doubleTap("#photo")
pinchOut("#map", scale: 2.5)
pinchIn("#map", scale: 0.4)
swipeBy("#map", dxRatio: -0.3, dyRatio: 0.0)   // 左へパン
```

## `gesture`: 指を離さずに続ける多点ジェスチャ

```swift
gesture("#pad_map") {
    FTFinger(x: 0.3, y: 0.35).hold(seconds: 0.3)
        .move(x: 0.6, y: 0.35, durationSeconds: 0.3)
        .move(x: 0.6, y: 0.65, durationSeconds: 0.3)
}
gesture("#pad_map") {                 // 指が2本 = 手組みのピンチ
    FTFinger(x: 0.45, y: 0.5).move(x: 0.2, y: 0.5, durationSeconds: 0.5)
    FTFinger(x: 0.55, y: 0.5).move(x: 0.8, y: 0.5, durationSeconds: 0.5)
}
```

`swipePointToPoint`(他のジェスチャ系コマンドも同様)を繰り返し呼ぶと呼ぶたびに指が離れますが、
`gesture` ブロック内の `FTFinger` は全部まとめて**1本の連続したタッチ列**として再生されます ——
指は押し始めてから move/hold を順にこなし、自分の経路の最後でだけ離れます。座標は
**対象の枠に対する比率**(0...1 が枠の内側。枠の外でも画面内なら書けます)なので、解像度に
依存せず同じジェスチャが使えます。セレクタを省略すると画面全体が対象になり、ブロック内では
ループや分岐も書けます。上限は 1〜5本・1本あたり最大625点・全体の秒数は既定10秒
(`maxGestureSeconds:` で最大60秒まで、他のジェスチャ系コマンドと同じ規則で上げられます)。
不正な指定(指0本・画面外の点・0以下の秒数・長すぎるジェスチャ)は、デバイスに触れずステップを
失敗させます。

**iOS では既定の hybrid エンジンでも常に XCUITest 経由で動きます** —— in-app エンジンには
この経路が無く(座標ピンチと同じ非公開の pointer-event API を使います)。用途はパターンロック・
長押しから離さないドラッグ(並べ替え等)・独自の2本指回転・3本指以上を要するジェスチャ・
描画や署名など。

## マップ・キャンバス系の画面

地図・画像ビューア・図面のような画面は、次の4つで操作します: `swipeBy` でパン(斜め含む)・
`pinchOut`/`pinchIn` でズーム・`doubleTap` でズームイン。注意点は3つあります:

- **ピンチはどの経路でも「領域」で狙い、指の位置はエンジンに関わらず同じです。** OS ごとの
  1つの規則(`FTCore.PinchGesture`。ホスト側)が指の座標を決め、in-app・XCUITest とも同じ
  座標を再生します。iOS は領域の長辺に沿って横に2本並べ両端の 0.8 内側、Android は領域の
  短辺の 90% の幅で中心に置きます。XCUITest はこの座標を非公開 API で送り、その API を
  持たない Xcode でだけ `accessibilityIdentifier` で要素を引いてピンチへ縮退し、
  そのことがステップの注記に残ります。
- **対象を書かない `pinchOut()` / `pinchIn()` は画面中央の狭い範囲に効きます**
  (画面全体ではありません)。**指の2点が別々のものに載るとピンチになりません** ——
  Apple マップでの実測(2026-09-22)では、画面全体でピンチすると下の指が検索カードに乗り、
  **縮小が地図のパンに化けました**(拡大は指が中央から開くので効く、という非対称がありました)。
  そこで**両方の指が同じものに載る位置**を選んで撃ちます。置けなければ半径を狭め、
  それでも駄目なときだけ従来どおり画面全体でピンチします。
- **iOS は Compose のダブルタップだけがエンジンによって成否が分かれます。** 既定の hybrid
  エンジンなら全フレームワーク・全ジェスチャが動き、ピンチは全フレームワークとも両エンジンで
  動きます。Android にはこの区別が無く、全ジェスチャがどこでも動きます:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter |
  |---|---|---|---|
  | `swipeBy`(斜め含む) | ✅ | ✅ | ✅ |
  | `doubleTap` | ✅ XCUITest | ✅ **in-app のみ** | ✅ |
  | `pinchOut` / `pinchIn` | ✅ XCUITest | ✅ | ✅ |
  | `gesture` | ✅ XCUITest | ✅ XCUITest | ✅ XCUITest |

  「in-app のみ」は、`xcuitest` 単独プロファイルや物理端末では効かないという意味です
  (物理端末は注入不可のため XCUITest しか経路がありません)。実測(2026-09-24)では、
  XCUITest ランナーの `/doubletap` が非公開の座標イベント API で2回の独立したタッチを送る
  ようになり、Flutter はこの形を検出します(React Native でも届きますが、タップを JS の
  PanResponder と時計で判定する画面は間欠的に取りこぼすことがあります)。一方**Compose だけは
  2タッチの間隔を変えても一度もダブルタップとして数えません** —— in-app エンジンが合成する
  タッチだけがそこで届きます。MCP の `ft_*` ツールも `profile` を渡せば同じエンジンで動きます。
- **指定した倍率どおりに出るとは限りません。** 2本指はピンチしている領域の外へは置けないため、
  極端な `scale` を指定してもその領域で出せる最大値で頭打ちになります。**倍率そのものより
  「拡大/縮小が起きたこと」を検証する**方が、アプリを跨いで安定します。

### Link
- [index](../index_ja.md)
