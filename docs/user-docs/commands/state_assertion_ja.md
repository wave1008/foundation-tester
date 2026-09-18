# enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF

直前に掴んだ要素の有効/無効・チェック状態を検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `select(selector).enabledIsTrue(timeout:)` | 要素が有効であることを検証します。`timeout` まで状態変化を待ちます。対象は直前に掴んだ要素です。 |
| `select(selector).enabledIsFalse(timeout:)` | 要素が無効であることを検証します。待機の挙動は同じです。 |
| `select(selector).checkIsON(timeout:)` | 要素がチェックされていることを検証します。 |
| `select(selector).checkIsOFF(timeout:)` | 要素がチェックされていないことを検証します。要素がチェック状態(オン/オフ)を一度も報告しなかった場合、run 終了時に警告が出ます。 |

いずれも `exist` / `select` の戻り値にチェーンでき、直前に掴んだ要素に効く暗黙形(自由関数。
例: `enabledIsTrue()`)も持ちます。

## 例

```swift
select("#login_btn").enabledIsFalse()
tap("#email"); type("test@example.com")
tap("#password"); type("password123")
select("#login_btn").enabledIsTrue()

select("#toggle_notifications").checkIsON()
```

## 注意点

- チェック状態はアクセシビリティから読みます。iOS は実装ごとに出し方が違い、fleetest はその違いを
  吸収します(selected trait・スイッチの値 `"1"`/`"0"`・React Native の `"checkbox, checked"` 等)。
- **状態を一切報告しない要素もあります**(例: SwiftUI の `Button` で自作したチェックボックス)。
  その要素に `checkIsON` を書くと「状態を報告していない」という理由で失敗します。
  画面に状態を表す文字があれば `textIs` で確かめるか、アプリ側で状態を公開してください
  (SwiftUI なら `.accessibilityRepresentation { Toggle(...) }`)。
- **オンのときだけ報告する実装**(iOS の Compose のチェックボックス等)では、同じシナリオで
  一度オンを確かめた要素に限り、報告が無いことをオフと判定します。一度もオンを見ていない要素の
  `checkIsOFF` は状態が分からないまま通り、run 終了時に警告が出ます。
- 「一部だけ選択」(indeterminate)の要素は、`checkIsON` でも `checkIsOFF` でも失敗します。

## 画像でチェック状態を判定する(CheckStateClassifier)

アクセシビリティが状態を出さない部品は、見本画像から学習した画像分類器で判定できます
(Shirates の Vision 版と同じ置き場所・同じラベルです)。

```
<プロジェクト>/vision/classifiers/CheckStateClassifier/
  [ON]/             オンの見本画像(png / jpg)
  [OFF]/            オフの見本画像
  [INDETERMINATE]/  一部だけ選択の見本画像(任意)
```

- 見本は、判定したい要素の**枠そのもの**をスクリーンショットから切り出したものを置きます
  (判定のときも要素の枠で切り出すため、切り方を揃えます)。
- `[INDETERMINATE]` に見本を置くと、一部だけ選択の見た目を indeterminate と判定し、`checkIsON` / `checkIsOFF` の両方が
  その理由で失敗します(fleetest 独自のラベルです)。置かないと、一部だけ選択の見た目もオンかオフに振られます。
- 分類器は見本のラベルのどれかを必ず答えます。**同じ画面のスイッチやラジオも判定に使う場合は、
  それらの見本も置いてください**(見本に無い見た目は誤りやすくなります)。
- 見本を置くと、初回の判定で学習します(数秒)。学習結果は `.fleetest/` に保存され、見本を
  変えたときだけ学び直します。
- 実行プロファイルの `preferCheckStateClassifier`(既定 `true`)で、アクセシビリティより分類器を
  優先します。`false` にすると、アクセシビリティが状態を報告しない要素にだけ使います。
- 画像で判定したステップには、結果に注記 `check-state-classified` が付きます。
- Shirates の `MLImageClassifier.swift` の `options=` / `imageFilter=binary` も同じ意味で読みます。
- 同じ仕組みで、要素の画像のラベルを検証する [imageIs](image_assertion_ja.md) もあります。
- 見本の切り出しと点検は `fleetest vision capture --classifier CheckStateClassifier --label "[ON]" --selector "#…"`
  と `fleetest vision check` でできます(詳しくは [imageIs](image_assertion_ja.md) のページ)。
- Android は `isChecked` と `isSelected` の両方を見ます — タブや選択行のように `isSelected` だけで
  選択状態を出す要素も、チェック済みとして認識されます。

### Link
- [index](../index_ja.md)
