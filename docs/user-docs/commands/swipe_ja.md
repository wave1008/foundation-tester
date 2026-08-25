# swipe

生のジェスチャです: 画面全体のスワイプ、2点間ドラッグ、要素間ドラッグ、要素からの比率ドラッグ。

## 関数

| 関数 | 説明 |
|---|---|
| `swipe(.up / .down / .left / .right)` | 画面全体を**指の動きの方向**でスワイプします。`scroll*` 系の「方向はコンテンツ基準」というルールの**唯一の例外**です。詳細は [scroll](./scroll_ja.md) 参照。 |
| `swipePointToPoint(startX:startY:endX:endY:durationSeconds: 1.5)` | 2点間をドラッグします。座標は snapshot の `screen` と同じ座標系です(iOS = pt / Android = px)。 |
| `swipeElementToElement(開始sel, 終点sel, durationSeconds: 1.5)` | ある要素から別の要素までドラッグします(スライダー・並べ替え・限られた領域内のドラッグ用)。ヒール(自己修復)対象は**始点だけ**で、終点はヒールされません。 |
| `swipeBy(sel?, dxRatio:dyRatio:durationSeconds: 1.5)` | 対象の中心から**比率**で指を動かします。横方向・縦方向の両方を非 0 にすると斜めのドラッグになります。比率の符号が指の向きを表します。セレクタを省略すると画面全体が対象になります。 |

## 例

```swift
swipe(.up)                                          // 画面全体をスワイプ(指は上へ動く)

swipePointToPoint(startX: 50, startY: 400, endX: 300, endY: 400, durationSeconds: 1.0)

swipeElementToElement("#slider_handle", "#slider_track_end")

swipeBy("#map", dxRatio: -0.3, dyRatio: -0.2, durationSeconds: 0.5)  // 斜めにパン
```

## 注意点

- **`swipe` だけが「指の動き」を方向として扱う**唯一のコマンドです。`scroll*` 系はすべて
  コンテンツ基準です(`.down` = 下方向へ読み進める = 指は上へ動きます)。
- `swipeBy` と `swipeElementToElement` は、地図・画像ビューア・図面のパン/ズームの土台になる
  コマンドです。詳細は [gestures](./gestures_ja.md) を参照してください。

### Link
- [index](../index_ja.md)
