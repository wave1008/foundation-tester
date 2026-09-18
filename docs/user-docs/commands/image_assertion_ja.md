# imageIs

直前に掴んだ要素の**画像**を、見本画像から学習した分類器(DefaultClassifier)で分類し、ラベルを検証します
(Shirates の Vision 版の `imageIs` の移植です)。

## 関数

| 関数 | 説明 |
|---|---|
| `select(selector).imageIs(label, timeout:)` | 要素の画像の分類結果のラベルが `label` を含むことを検証します。`timeout` まで取り直しながら待ちます。 |
| `imageIs(label, timeout:)` | 直前に掴んだ要素に対する暗黙形です。 |

## 見本画像の置き場所

```
<プロジェクト>/vision/classifiers/DefaultClassifier/
  @i/Settings/[Camera Icon]/   見本画像(png / jpg)
  @i/Settings/[General Icon]/
  ...
```

- ラベルは画像の親フォルダです。フォルダは何段でも入れ子にできます(OS や画面ごとに分けるなど)。
- 判定で見るのは、ラベルの**最後の `[` 以降**です(`[Camera Icon]`)。同じ `[…]` を2つのフォルダに置くと
  設定の誤りとして失敗します。
- 見本は、判定したい要素の**枠そのもの**をスクリーンショットから切り出したものを置きます
  (判定のときも要素の枠で切り出すため、切り方を揃えます)。
- 分類器は必ず、見本のどれかのラベルを答えます。**見分けたい要素だけでなく、同じ画面で紛らわしい要素の見本も
  置いてください**(ラベルが2つ以上必要です)。
- `#` で始まるファイルは学習に使いません。`MLImageClassifier.swift` の `options=` / `imageFilter=binary` も
  Shirates と同じ意味で読みます。
- 見本を置くと、初回の判定で学習します(数秒)。学習結果は `.fleetest/` に保存され、見本を変えたときだけ
  学び直します。
- チェック状態を画像で判定する [CheckStateClassifier](state_assertion_ja.md) と同じ仕組みです
  (分類器ごとにフォルダが分かれています)。

## 例

```swift
select("#settings_camera").imageIs("[Camera Icon]")
```

## 注意点

- 見本が無い、または `label` を含むラベルの見本が無いときは、待たずに失敗します。
- 失敗の文言には、分類されたラベルと確信度が出ます。

### Link
- [index](../index_ja.md)
