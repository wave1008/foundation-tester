# メモ(writeMemo, readMemo, clearMemo, memoTextAs)

シナリオ間で値を共有します。`@Test` は1本ずつ別プロセスで動くので Swift の変数は引き継がれませんが、
メモは**同じデバイスで後から走るシナリオ**へ引き継がれます(別のデバイスへは渡りません。下の「共有の範囲」)。名前と挙動は Shirates に合わせています。

## 関数

| 関数 | 説明 |
|---|---|
| `writeMemo(key, text)` | キーの履歴に `text` を追記します。 |
| `readMemo(key) -> String` | キーの**最後の値**を返します。無ければ `""`(失敗にはしません。ステップに注記 `memo-key-not-found` が付きます)。 |
| `clearMemo()` | メモを全部消します。 |
| `element.memoTextAs(key)` | 掴んだ要素のテキスト(ラベル → 値のうち空でない最初のもの)を書き、要素を返します。要素を掴めていなければ失敗します。 |
| `string.memoTextAs(key)` | 文字列を書き、その文字列を返します。 |

## 共有の範囲

- メモは**1回の run の同じデバイスで動くシナリオ**で共有されます。別のデバイスで書いた値は見えません
  (`readMemo` は `""` を返し、注記 `memo-key-not-found` が付きます)。次の run へは持ち越しません。
- 単発の呼び出し(MCP や、ランナーを手で直接起動した実行)は空のメモから始まります。
- 確実な使い方は「**`setUpDevice()` で書き、各テストで読む**」です。デバイスに最初に配られたシナリオが
  先に `setUpDevice()` を走らせるので、他のシナリオがどこに配られても値が存在します。
- `setUpDevice()` が失敗すると、そのデバイスで同じクラスの残りのシナリオは実行されずに失敗として
  記録されます。`setUpDevice()` は1回の run のデバイスごとに高々1回で、結果が不明でも撃ち直さず、
  デバイスが復旧しても再実行しません。
- `tearDownDevice()` もメモを読めます(デバイスの仕事がすべて終わった後に走るので、その時点の最後の値が見えます)。

## 例

```swift
@TestClass(app: "com.example.myapp")
class OrderFlow {
    func setUpDevice() {
        launchApp()
        select("#shop_name").memoTextAs("shop")
    }

    @Test("レシートに店名が出る")
    func S0010() {
        scenario {
            scene(1, "確認する") {
                expectation { select("#receipt_shop").textIs(readMemo("shop")) }
            }
        }
    }
}
```

### Link
- [index](../../index_ja.md)
