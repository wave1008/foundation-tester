# imageIs

直前に掴んだ要素の**画像**を、見本画像から学習した分類器(DefaultClassifier)で分類し、ラベルを検証します
(Shirates の Vision 版の `imageIs` の移植です)。

## 関数

| 関数 | 説明 |
|---|---|
| `select(selector).imageIs(label, waitSeconds:)` | 要素の画像の分類結果のラベルが `label` を含むことを検証します。`waitSeconds` まで取り直しながら待ちます。 |
| `imageIs(label, waitSeconds:)` | 直前に掴んだ要素に対する暗黙形です。 |

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
- `imageIs` が失敗すると、分類器が判定に使ったスクリーンショットを、レポートの失敗したステップのすぐ下に添えます。
- 判定のたびに、置いた見本のうち2枚も分類し直します。分類器がそれを取り違えたら(Mac の Vision / Core ML が一時的に
  壊れている)答えを使わず、`imageIs` はその理由で失敗します。


## 見本の切り出しと点検(CLI)

見本は手で切り出さず、稼働中の端末から切り出せます。判定のときと同じ関数で要素の枠を切るので、切り方がずれません。

```sh
fleetest vision capture --project <プロジェクト> --classifier DefaultClassifier \
  --label "@i/Settings/[Camera Icon]" --selector "#要素の id" --port <ブリッジのポート>
fleetest vision check --project <プロジェクト>
```

- `vision capture` は、ラベルが分類器に合わない(``[` で終わらないフォルダ名`)、同じラベルが別のフォルダにある、といった誤りを
  保存前に断ります。
- `vision check` は必要なら学習してから、**分類器が自分の見本を取り違えないか**を確かめます。取り違えた見本は
  名指しで警告します(見本どうしが見分けられていない = 本番でも取り違えうる)。警告だけで、終了コードは 0 です。
- シナリオの実行中に取り違えが見つかった場合も、シナリオの終わりに同じ警告が出ます。
- MCP からは `ft_capture_element` で同じことができます(`ft_snapshot` の ref でも要素を指せ、保存後の点検結果も返ります)。

## 例

```swift
select("#settings_camera").imageIs("[Camera Icon]")
```

## 注意点

- 見本が無い、または `label` を含むラベルの見本が無いときは、待たずに失敗します。
- 失敗の文言には、分類されたラベルと確信度が出ます。

### Link
- [index](../index_ja.md)
