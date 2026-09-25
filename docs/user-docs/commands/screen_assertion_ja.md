# screenLooksLike

FM(Foundation Models)による見た目の画面検証です。スクリーンショットと、あなたが書く説明文を照合します。

## 関数

| 関数 | 説明 |
|---|---|
| `screenLooksLike("説明文")` | 現在の画面が説明文と一致するかを FM に判定させます。実行プロファイルで `screenLooksLike: false` の場合はスキップ(素通り)します。 |

## 例

```swift
expectation {
    screenLooksLike("メールアドレスとパスワードの入力欄、ログインボタンがあるログイン画面")
}
```

## 注意点

- **experimental** です。説明文は日本語でも書けますが、日本語の説明文での判定精度はまだ
  計測していません。詳細は [environments_ja.md](../overview/environments_ja.md)。
- **macOS 27+ が必要**です。macOS 26 では自動でスキップされます。現在の可否は `fleetest doctor` で確認できます。
- **厳密な合否ゲートとしては使わないでください。** 判定は説明文の言い回しに強く依存し(言語だけでは
  決まりません)、見た目は同じ画面でもスクリーンショットの撮られ方によって合否が裏返ることがあります
  (同一の画像に対しては決定的です)。使うなら大づかみの確認に留め、失敗させたくない検証は
  `exist` / `textIs` / `countIs` のような木ベースのアサーションで書いてください。
- Shirates(Classic)の `screenIs` のような画面ニックネーム機構は持ちません — 画面がどう見えるべきかを
  呼び出しごとに説明文で書きます。

### Link
- [index](../index_ja.md)
