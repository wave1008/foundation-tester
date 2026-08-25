# wait, waitForDisplay, waitForClose

固定待ちと、要素の出現・消滅を明示的に待つコマンドです。

## 関数

| 関数 | 説明 |
|---|---|
| `wait(秒)` | 固定待ち。小数可。 |
| `waitForDisplay(sel, waitSeconds: 15)` | 要素が表示されるまで待ちます(**スクロールしません**)。戻り値は `FTElement` で、`exist` と同様にチェーンできます。見つからなければシナリオを失敗させます。 |
| `waitForClose(sel, waitSeconds: 15)` | 要素が消えるまで待ちます(**スクロールしません**)。`sel` は省略できません(直前セレクタを再利用する省略形はありません)。 |

## 例

```swift
tap("#submit")
waitForDisplay("#confirmation_toast", waitSeconds: 10)
waitForClose("#loading_spinner", waitSeconds: 15)
wait(0.5)     // セレクタで待てない整定のときだけ(アニメ中の座標ずれ等)
```

## 注意点

- **要素の出現待ちは既に暗黙です** —— 操作は解決を再試行し、検証はタイムアウトまでポーリング
  再判定するので、`exist()` の前に `wait()` を置くのは冗長です。待ちが足りなければ固定の
  `wait()` を足すのではなく、コマンドの `timeout:`(小数可)を上げてください。
- **`wait()` はセレクタで待てない整定のための最後の手段です**(アニメ中に座標がずれる等)。
  `waitForDisplay` / `waitForClose` の代わりにはなりません。
- **`waitForDisplay` の判定は `exist` と同じ可視性込み**です(コマンド名 displayed の意味に
  沿わせています)—— `exist` の `requireVisible: false` に当たる逃げ道はありません。覆われ
  検出を外したまま待ちたい場合は `exist(sel, requireVisible: false, timeout: 15)` を使って
  ください。
- `waitForDisplay` / `waitForClose` はどちらもスクロールして探しません。画面外にある可能性が
  あるなら、先にスクロールするか `scrollTo` を使ってください。

### Link
- [index](../index_ja.md)
