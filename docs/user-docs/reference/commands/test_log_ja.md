# 出力フォルダと一時フォルダ(TestLog)

[in English](test_log.md)

シナリオの中でファイルを書くときに使うフォルダを返します。シナリオはサンドボックスの中で動くので、
**書けるのはこの2つのフォルダ(とその下)だけ**です。`NSTemporaryDirectory()` や
`FileManager.default.temporaryDirectory` が返す場所には書けません(「You don’t have permission」で失敗します)。
`TestLog.directoryForLog` の名前と単位は Shirates に合わせています。

## プロパティ

| プロパティ | 説明 |
|---|---|
| `TestLog.directoryForLog: URL` | このテストクラスの出力フォルダ。`<レポートの出力先>/<run の開始 yyyy-MM-dd_HHmmss>/<テストクラス名>/`。同じ run の同じクラスのシナリオで共有します。レポートと一緒に残ります。 |
| `TestLog.directoryForTemp: URL` | このシナリオ専用の一時フォルダ。**シナリオが終わると消えます**。並列に走る他のシナリオとは共有しません。 |

どちらも初めて読んだときにフォルダが作られます。

## 残るもの・消えるもの

- `directoryForLog` に書いたものはレポートと同じく残り、保持容量の掃除の対象になります(古い日から消えます)。
  別の Mac で実行した場合(`--runner`)も、レポートと一緒に手元へ回収されます。
- `directoryForTemp` はシナリオの終わりに中身ごと消えます。残したいものは `directoryForLog` へ書いてください。
- dry-run でもシナリオのコードは動くので、どちらも使えます(dry-run の出力先は使い捨てです)。
- シナリオの外(MCP の `ft_batch` など)では使えません。

## 例

```swift
@Test("価格の一覧を書き出す")
func S0010() {
    scenario {
        scene(1, "一覧を保存する") {
            action {
                let csv = TestLog.directoryForLog.appendingPathComponent("prices.csv")
                try? "name,price\n".write(to: csv, atomically: true, encoding: .utf8)

                let work = TestLog.directoryForTemp.appendingPathComponent("unzipped")
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            }
        }
    }
}
```

### Link
- [index](../../index_ja.md)
