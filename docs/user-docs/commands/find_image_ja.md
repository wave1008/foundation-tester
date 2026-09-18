# findImage, findImages, existImage

画面の中から、見本画像に最も近い見た目の要素を探します(Shirates の Vision 版の `findImage` / `findImages` の移植です)。
id もラベルも持たないアイコンのように、セレクタで指せない要素を掴むときに使います。
`existImage` は同じ探し方で、画像が画面にあることを検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `findImage(label, threshold:, aspectRatioTolerance:, timeout:, scroll:, maxSwipes:)` | 見本画像に最も近い要素を1つ掴みます。見つからなくても失敗せず、空の要素を返します(`.isEmpty` で分岐します)。既定では今の画面を1回だけ見ます(`timeout` 既定 0)。出るのを待つときは `timeout` に秒数を渡します。 |
| `findImages(label, threshold:, aspectRatioTolerance:)` | `threshold` を下回る要素を、近い順にすべて返します(`[FTElement]`)。今の画面を1回だけ見ます(待たない・スクロールしない)。`threshold: nil` なら絞りません。 |
| `existImage(label, threshold:, aspectRatioTolerance:, timeout:, scroll:, maxSwipes:)` | 見本画像が画面にあることを検証します(Shirates の Vision 版の `existImage` の移植)。探し方は `findImage` と同じで、**見つからなければ失敗**します。見つけた要素を返します。`timeout` を省くと、実行プロファイルの既定の待ち時間まで、出るのを待ちます(`exist` と同じ)。 |
| `element.tap(holdSeconds:)` | 掴んだ要素をタップします。`findImage` / `findImages` で掴んだ要素は、見つけた枠の中心を座標でタップします。 |

## 探し方

1. 見本画像を DefaultClassifier の見本から探します。ラベル(フォルダ)が `label` で終わるフォルダの画像を使い、
   `@i`(iOS)/ `@a`(Android)の付いた、実行中の OS 向けのものを先に試します。
2. 画面のアクセシビリティ要素を、要素の枠でスクリーンショットから切り出します。見本と**アスペクト比が近い**要素
   (許容幅 `aspectRatioTolerance`、既定 0.2)だけを、近い順に候補にします。
3. 候補ごとに、見本との**画像特徴量の距離**(Vision の FeaturePrint。小さいほど似ている)を測ります。
4. `findImage` は最も近い1件が `threshold`(既定 0.15)以下なら掴みます。超えたときは、その1件を
   DefaultClassifier に掛けます([imageIs](image_assertion_ja.md) と同じ分類器)。ラベルが一致し、さらにそのラベルの
   見本のどれかとの距離が `threshold` 以下(または分類の確信度が `threshold` 以下)のときだけ掴みます。
   分類器は見本のどれかのラベルを必ず答えるので、ラベルの一致だけでは掴みません。

## 見本画像の置き場所

[imageIs](image_assertion_ja.md) と同じ見本を使います。

```
<プロジェクト>/vision/classifiers/DefaultClassifier/
  @i/Home/[Camera Icon]/   見本画像(png / jpg)
  @a/Home/[Camera Icon]/
```

- 見本は、探したい要素の**枠そのもの**を切り出したものを置きます(`fleetest vision capture` か MCP の
  `ft_capture_element` で切り出せます)。
- `findImages` は見本を1枚だけ使います(実行中の OS 向けのものを優先)。

## 例

```swift
findImage("[Camera Icon]").tap()

let icon = findImage("[Camera Icon]", timeout: 3)
if icon.isEmpty {
    // 見つからなかったとき
}

findImage("[Share Icon]", scroll: .down).tap()

let stars = findImages("[Star Icon]")
stars.first?.tap()

existImage("[Camera Icon]")
existImage("[Share Icon]", scroll: .down).tap()
```

## 注意点

- 記録には距離と比べた候補の数が出ます(見つからなかったときは最も近かった距離)。`threshold` を決めるときの目安にしてください。
- **文字だけが違う同じ形の部品(リストの行など)は見分けにくい**です。実測では同じ見た目のボタン行どうしの距離が
  0.08〜0.15 で、既定の `threshold`(0.15)では別の行を掴みました。こうした部品を探すときは、記録の距離を見て
  `threshold` を絞ってください(例: `threshold: 0.03`)。
- 1回の所要の目安は、スクリーンショット約 0.1 秒 + 候補1件あたり約 8 ミリ秒です(シミュレータでの実測)。
- `timeout` の既定は 0 で、今の画面を1回だけ見ます(実行プロファイルの既定の待ち時間には従いません)。画面が切り替わった直後など、
  画像が出るのを待つときは `timeout: 3` のように秒数を渡してください。スクロールしながら探すときは、位置ごとに1回だけ見ます。
- `existImage` が失敗したときは、失敗の文言に最も近かった距離と `threshold` が出て、判定に使ったスクリーンショットがレポートの
  そのステップに添えられます。待っている間は、間隔を広げながら(0.1 秒から最大 1 秒)スクリーンショットを撮り直して比べます。
- `withScrollDown { }` などの中では、`findImage` も `existImage` もスクロールしながら探します。今の画面だけを見るときは
  `scroll: .noScroll` を渡します(`existImage("[Icon]", scroll: .noScroll)`)。
- スクロールしながら探すときは `scroll:` を渡します(`findImage("[Icon]", scroll: .down)`)。`exist` や `select` と同じ書き方です。
  `findImageWithScrollDown` や `tapWithScrollDown` のような関数名の別名は、どのコマンドにもありません(書くとコンパイルエラーが正しい書き方を示します)。
- 見本が1枚も無いときは、設定の誤りとして失敗します。
- まれに、Mac の画像処理(Vision)が一時的にどの画像にも同じ特徴量を返す状態になります。そのまま比べると
  最初の候補を「見つけた」ことにしてしまうので、この状態は検知して失敗にします(文言は
  `Vision returned the same image feature print for different images`)。run をやり直してください。
- 見つけた要素に書けるセレクタ(id か一意なラベル)があれば、`textIs` などの検証をつなげられます。
- 見つけてから画面を動かすと、`tap()` は古い座標をタップします。見つけた直後にタップしてください。
- 画像の区分けで部品を切り出す Shirates と違い、切り出しはアクセシビリティ要素の枠です。アクセシビリティに
  出てこない部品は探せません。

### Link
- [index](../index_ja.md)
