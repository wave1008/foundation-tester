# enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF

直前に掴んだ要素の有効/無効・チェック状態を検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `select(selector).enabledIsTrue(timeout:)` | 要素が有効であることを検証します。`timeout` まで状態変化を待ちます。対象は直前に掴んだ要素です。 |
| `select(selector).enabledIsFalse(timeout:)` | 要素が無効であることを検証します。待機の挙動は同じです。 |
| `select(selector).checkIsON(timeout:)` | 要素がチェックされていることを検証します。 |
| `select(selector).checkIsOFF(timeout:)` | 要素がチェックされていないことを検証します。チェック状態が一度も観測できていない場合、run 終了時に警告が出ます。 |

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

- iOS はアプリの実装により checked が取れないことがあります(要素によっては一切報告されません)。
- Android は `isChecked` と `isSelected` の両方を見ます — タブや選択行のように `isSelected` だけで
  選択状態を出す要素も、チェック済みとして認識されます。

### Link
- [index](../index_ja.md)
