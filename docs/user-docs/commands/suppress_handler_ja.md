# suppressHandler, useHandler, disableHandler, enableHandler

宣言済みの [`irregularHandler`](./irregular_handler_ja.md) に自動で閉じさせず、シナリオ自身が
モーダルを操作するための区間を作ります。

## 関数

| 関数 | 説明 |
|---|---|
| `suppressHandler { }` | 宣言済みの割り込みを自動で閉じない区間を作り、シナリオ自身がモーダルを検証・操作できるようにします。**ブロック形**なので、途中で失敗しても抑止はブロックを抜けるときに必ず戻ります。 |
| `useHandler { }` | `suppressHandler`(または `disableHandler()`/`enableHandler()` の間)の内側で、そのブロックだけ自動クローズを戻します。 |
| `disableHandler()` | `enableHandler()` まで宣言済みの割り込みを自動で閉じなくします。`suppressHandler` と違い、`condition` / `action` / `expectation` のブロックを跨げます。 |
| `enableHandler()` | `disableHandler()` が止めていたものを再開します。 |

## 例

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")   // 宣言は setUp のままでよい
}

suppressHandler {
    exist("#promo_modal")          // 出たことを検証する
    tap("#btn_promo_detail")       // 自分で操作する
}                                   // 抜けたら自動クローズが戻る
```

`condition` / `action` / `expectation` の境界を跨ぐときは命令形が必要です
(`suppressHandler { }` は1つのブロックの内側にしか置けません)。

```swift
condition {
    disableHandler()
    exist("#promo_modal")       // 出たことだけ確かめておく
}.action {
    tap("#btn_promo_detail")    // 別のブロックでも止まったまま
}.expectation {
    exist("#detail_screen")
    enableHandler()             // ここから自動クローズが戻る
}
```

## 注意点

- **`suppressHandler { }` はブロック形**なので、途中で失敗しても抜けるときに自動クローズが
  戻ります。モーダルとのやり取りが1つのブロックに収まるときはこちらを使ってください。
- **`condition` / `action` / `expectation` を跨げるのは `disableHandler()` / `enableHandler()`
  だけ**です —— `condition {}` でモーダルの存在を確かめ、`action {}` で操作したいときはこちらを
  使います。
- **`useHandler { }` は入れ子のブロックだけ自動クローズを戻します**。外側の抑止(`suppressHandler`
  または `disableHandler()`)は終わらず、入れ子のブロックを抜けると再び抑止に戻ります。
- **抑止しても、アプリが割り込みを出すこと自体は止められません** —— 止まるのは「ツールが
  閉じること」だけです。モーダルが出ているあいだに送ったタップは、それでも吸われることが
  あります。吸われた操作の扱いは [irregularHandler](./irregular_handler_ja.md) を参照して
  ください。
- 抑止したままステップが失敗すると、失敗の注記に
  「a declared interruption was on screen but automatic closing is suppressed here」が
  追加されます —— 成功しているステップには何も足されません。
- **`disableHandler()` の後に `enableHandler()` を呼び忘れると、抑止はシナリオの終わりまで
  効いたままになります** —— 中断した場合、その後に実行されるのは `tearDown()` だけなので、
  片付けの最中に出た割り込みも自動では閉じられません。これが気になる場合はブロック形を
  使ってください。
- OS のシステムダイアログ(権限の許可等)はどちらにも影響されません —— あちらは別の機構です
  ([iosAlertHandler](./ios_alert_handler_ja.md) 参照)。とくに、シナリオが直接操作している
  アラート(`tap("許可")` や `ifCanSelect`)は、抑止の有無に関わらず奪われません。

### Link
- [index](../index_ja.md)
