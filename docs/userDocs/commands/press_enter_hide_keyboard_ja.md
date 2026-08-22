# pressEnter, hideKeyboard

キーボードの確定アクションを発火する、またはソフトキーボードを閉じます。

## 関数

| 関数 | 説明 |
|---|---|
| `pressEnter()` | フォーカス中の入力欄へ Enter/IME アクション(検索・完了・送信・改行など)を発火します。 |
| `hideKeyboard()` | ソフトキーボードを閉じます。**Android のみ**対応です(出ているときだけ戻るキーを撃つので、常に呼んでも安全です)。**iOS は未対応で失敗します** —— iOS で閉じたいときは代わりに `pressEnter()` を使ってください(単一行の欄ならこれで閉じます)。 |

## 例

```swift
type("#search_box", "腕時計")
pressEnter()               // 欄の確定アクションを発火

android {
    hideKeyboard()
}
```

## 注意点

- `pressEnter()` が改行を入れるか確定アクションを発火するかはフィールド側が決めます(コマンド
  側では選べません)。`type` の末尾 `\n` についても同じ話が当てはまります。詳細は
  [type](./type_ja.md) 参照。
- キーボードが表示されているかどうかの検証は別の検証コマンドです。
  [キーボードの検証](./keyboard_assertion_ja.md)を参照してください。

### Link
- [index](../index_ja.md)
