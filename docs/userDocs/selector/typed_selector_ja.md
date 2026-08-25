# 型付きセレクタ(`Sel`)

セレクタ式は文字列1本なので、綴り誤りをコンパイラでは捕まえられず、実行時の構文検証に頼ることに
なります。`Sel` は同じセレクタ記法を型で書けるようにしたもので、文字列版に**併設**されます
(置き換えではありません)。

## 例

```swift
tap(.id("login_btn"))                            // #login_btn
tap(.id("login_btn").or(.text("ログイン")))        // #login_btn||ログイン
tap(.id("list").find(.type(.cell).nth(2)))       // #list >> .cell[2]
tap(.text("通知").right(.switch))                 // 通知:rightSwitch
exist(.type(.button).text("保存", .contains))     // .button&&textContains=保存
```

対象セレクタを取るコマンドは全て `String` 版と `Sel` 版のオーバーロードを持ちます。
どちらを書いても構いません —— 内部で組み立てられるロケータは同一なので、実行・レポート・
自己修復の挙動はどちらの書き方でも変わりません。

## 語彙

- `.id(_)`、`mode` に `.exact` / `.contains` / `.startsWith` / `.endsWith` / `.matches` を
  取る `.text(_, mode)`、`.value(_)`、`.placeholder(_)`、`.type(_)`、`.checked(_)`、
  `.enabled(_)`、`.nth(_)`(1 オリジンの序数)。
- `.or(_)`(和集合)と `.find(_)`(子孫へのスコープ)で合成します。
- 相対: `.right(_)`、`.left(_)`、`.above(_)`、`.below(_)`。文字列版の相対セレクタと同じく、
  任意の `matching:` フィルタと `nth:`(近い順の序数)を取れます。
- 型名: `.button`、`.staticText`、`.textField`、`.secureTextField`、`.switch`、それに
  エイリアス `.input`、`.widget`、`.cell`、`.image`、`.clickable`。この語彙に無い型は
  `.custom("...")` で書きます。

フィルタ系メソッド(`.text`、`.type`、`.nth` など)は常に**現在の対象**に効きます —— 相対
ステップより前なら基準、後なら解決済みの候補が対象です。

## 注意点

- 綴り誤り(`.buton`)は `Sel` では**コンパイルエラー**になります。文字列版の `"buton"` は
  良くて実行時の構文エラー、悪ければ黙って生ラベル扱いになります。
- **`scrollFrame:` だけは文字列版のみ**です —— 他の引数が `Sel` 版を持つコマンドでも、
  この引数には `Sel` 版がありません。
- 生成されるコード(VSCode 拡張のライブ操作録画・Claude Code によるシナリオ作成)は
  **既定で文字列版を出力します**。`Sel` は手書きで型指定を好む人のための選択肢です。

この記法が対応する完全なリファレンスは[セレクタ式](./selector_expression_ja.md)を参照してください。

### Link
- [index](../index_ja.md)
