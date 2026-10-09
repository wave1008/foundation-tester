# マップ・キャンバス系のジェスチャ(doubleTap, pinchIn, pinchOut, gesture, hold)

[in English](gestures.md)

マルチタッチのジェスチャです: ダブルタップ、拡大のためのピンチアウト、縮小のためのピンチイン、
そしてこの3つで表せない動きを組む生のジェスチャビルダー。

## 関数

| 関数 | 説明 |
|---|---|
| `doubleTap(sel?, settle:)` | ダブルタップします。セレクタ省略時は画面中心をタップします。`tap` を2回書いても代用にはなりません —— 往復で OS のダブルタップ判定時間を超えてしまいます。 |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5, maxGestureSeconds:, settle:)` | 2本指を開きます = 拡大。`scale` は 1 より大きい値のみ指定できます。`durationSeconds` の上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます。 |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5, maxGestureSeconds:, settle:)` | 2本指を閉じます = 縮小。`scale` は 0 より大きく 1 未満の値のみ指定できます。上限は `pinchOut` と同じです。 |
| `gesture(sel?, maxGestureSeconds:settle:waitSeconds:) { FTFinger(x:y:).move(x:y:durationSeconds:).hold(seconds:) }` | 指1本以上の経路を、離さない1本のタッチ列として再生します —— パターンロック・長押しからのドラッグ・2本指回転など、`pinchOut`/`pinchIn`/`doubleTap`/`swipeBy` で表せない動き用です。 |
| `hold(sel, holdSeconds: 3, maxGestureSeconds:, settle:, waitSeconds:, scroll:, maxSwipes:) { … }` | 指を下げたままブロックを実行します(押している間だけ出る部品の確認用)。`holdSeconds` の既定は 3 秒です。下の「`hold`」の節を参照してください。 |

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
指を遅れて下ろすには `FTFinger(x:y:startSeconds:)` を使います(`startSeconds` はジェスチャの
開始から指を置くまでの秒数で、既定 0。2本目以降の指をずらして置く用途です。0 以上の有限の値のみ)。
不正な指定(指0本・画面外の点・0以下の秒数・長すぎるジェスチャ)は、デバイスに触れずステップを
失敗させます。

**iOS では既定の hybrid エンジンでも、このコマンドは常に XCUITest 経由で動きます。** 用途はパターンロック・
長押しから離さないドラッグ(並べ替え等)・独自の2本指回転・3本指以上を要するジェスチャ・
描画や署名など。

## `hold`: 押している間だけ出る部品の確認

`tap(sel, holdSeconds:)` は1ステップの中で押して離すので、指が下がっている間だけ出る部品
(ツールチップ等)は、その後の処理が走る時点で既に消えています。`hold` はブロックの間
指を下げたままにします:

```swift
hold("#btn_tooltip_anchor", holdSeconds: 3) {
    select("#txt_tooltip").textIs("これはツールチップです")
}
```

指は `holdSeconds` 秒後に自動で離れ、ブロックはその間、指が下がったまま走ります。ブロックが `holdSeconds` より早く終われば、`hold` は
指が離れるまで待ってから返ります。ブロックが `holdSeconds` より長く掛かった場合は、それ以降
指が上がった状態でブロックの残りが走ります(失敗にはせず注記だけ残します)。**hold は入れ子にできません**
(前の hold のブロックが終わってから次の hold を始めてください)。対象が解決できなければブロックは
実行されません。**iOS の既定 hybrid エンジンでは、この押下は常に XCUITest 経由で動きます**
(`tap` の長押しと同じ)。

## マップ・キャンバス系の画面

地図・画像ビューア・図面のような画面は、次の4つで操作します: `swipeBy` でパン(斜め含む)・
`pinchOut`/`pinchIn` でズーム・`doubleTap` でズームイン。注意点は3つあります:

- **ピンチの指の位置はエンジンに関わらず同じです。** iOS は領域の長辺に沿って横に2本並べ両端の 0.8 内側、
  Android は領域の短辺の 90% の幅で中心に置きます。古い Xcode では別の方法に切り替わり、
  そのことがステップの注記に残ります。
- **対象を書かない `pinchOut()` / `pinchIn()` は画面中央の狭い範囲に効きます**
  (画面全体ではありません)。**指の2点が別々のものに載るとピンチになりません** ——
  画面全体でピンチすると片方の指が別の部品に載り、ピンチが地図のパンに化けることがあります。
  そのため両方の指が同じ要素に載る位置を選び、置けなければ半径を狭めます。
  それでも置けないときだけ画面全体でピンチします。
- **iOS では、ダブルタップだけがフレームワークとエンジンによって効かないことがあります。**
  既定の hybrid エンジン(Simulator)なら全フレームワーク・全ジェスチャが動きます。
  Android にはこの区別が無く、全ジェスチャがどこでも動きます:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter | React Native |
  |---|---|---|---|---|
  | `swipeBy`(斜め含む) | ✅ | ✅ | ✅ | — |
  | `doubleTap` | ✅ | ✅ **hybrid のみ** | ✅ | △ |
  | `pinchOut` / `pinchIn` | ✅ | ✅ | ✅ | ✅ |
  | `gesture` | ✅ | ✅ | ✅ | ✅ |

  - **「hybrid のみ」**: 既定の hybrid エンジン(Simulator)でだけ動きます。**`xcuitest` だけの
    プロファイルと実機では、Compose のアプリはダブルタップを認識しません**(実機はアプリへの
    注入ができないため、ほかに撃つ手段がありません)。
  - **「△」**: 届きますが、アプリがタップを JavaScript(PanResponder と時計など)で判定している
    画面では、間欠的に取りこぼすことがあります。
  - **「—」** は未確認です。
  - MCP からの使い方は [MCP サーバ](../tools/mcp_server_ja.md) を参照してください。
- **ダブルタップが効かない構成では、拡大の確認に `pinchOut` を使ってください。** 地図・写真の
  ように、ダブルタップが「拡大」を意味する画面なら、`pinchOut` で同じ拡大を起こして確かめられます。
  ピンチは Compose を含む全フレームワークで、どのエンジンでも動きます:

  ```swift
  // doubleTap("#map") の代わりに
  pinchOut("#map")
  select("#zoom_level").textIs("x2")
  ```

  ダブルタップが拡大以外の操作(「いいね」など)に割り当てられている画面では代わりになりません。
  その確認は Simulator(hybrid)か Android で行ってください。
- **指定した倍率どおりに出るとは限りません。** 2本指はピンチしている領域の外へは置けないため、
  極端な `scale` を指定してもその領域で出せる最大値で頭打ちになります。**倍率そのものより
  「拡大/縮小が起きたこと」を検証する**方が、アプリを跨いで安定します。

## 注意点

- **`settle: false`** を渡すと、このコマンドの操作後の「画面が落ち着くまでの待ち」を省きます(次のステップは動いている最中の画面を見ることがあります)。詳細は [tap](./tap_ja.md) 参照。

### Link
- [index](../../index_ja.md)
