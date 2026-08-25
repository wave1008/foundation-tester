# screenLooksLike

FM(Foundation Models)による見た目の画面検証です。スクリーンショットと、あなたが書く説明文を照合します。

## 関数

| 関数 | 説明 |
|---|---|
| `screenLooksLike("説明文")` | 現在の画面が説明文と一致するかを FM に判定させます。実行プロファイルで `fm: false` または `screenLooksLike: false` の場合はスキップ(素通り)します。 |

## 例

```swift
expectation {
    screenLooksLike("メールアドレスとパスワードの入力欄、ログインボタンがあるログイン画面")
}
```

## 注意点

- **experimental で、現時点では英語のみ**です。説明文は英語で書いてください —— Apple の
  オンデバイスモデルは 2026 年内は日本語に対応せず(日本語サポートは 2027 年の見込み)、
  そもそも FM を動かすには Mac のシステム言語が英語である必要があります。
  詳細は [environments_ja.md](../overview/environments_ja.md)。
- **macOS 27+ が必要**です。macOS 26 では自動でスキップされます。現在の可否は `fleetest doctor` で確認できます。
- Shirates(Classic)の `screenIs` のような画面ニックネーム機構は持ちません — 画面がどう見えるべきかを
  呼び出しごとに説明文で書きます。

### Link
- [index](../index_ja.md)
