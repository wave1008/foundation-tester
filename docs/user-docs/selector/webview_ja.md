# WebView 内の要素

ネイティブの WebView(iOS `WKWebView` / Android `android.webkit.WebView`)の中身も、
ネイティブ要素と同じセレクタ・同じコマンドで操作できます。ただし、ネイティブ画面と規約が
3点だけ異なります。

## `#id` が使えるかは読み取り経路で決まる

HTML の `id` 属性を `#id` として使えるかどうかは、木の読み取り方法によって決まります。
DOM を直接読める経路(iOS の既定エンジン、Android の WebView・ブラウザ)や、a11y が id を
出す構成(Android WebView 150 以降)では使えます。**iOS の `xcuitest` エンジンでは出ません**
—— WebKit が HTML の `id` を a11y へ渡さないためです。iOS の既定エンジン(hybrid)は WebView
の中身の読み取り・委譲を自動で行うため、シナリオ側で特別な書き分けは不要です。

## リンクは2要素で出る

リンクは同じラベルを持つ `.link` と `.staticText` の2要素として出ます(両 OS 共通)。
そのためラベル単独では曖昧になります。型で絞ってください: `.link&&ラベル`。

## 入力欄は2節で書く

```swift
// フィールドの id は "email_input"、placeholder は "Email"
type("#email_input||#Email", "user@example.com")
```

入力欄のセレクタは、**`#` の節を2つ `||` で繋いで**書きます —— フィールドの `id` の節と、
placeholder の節です。`#x` は identifier で引けなければ placeholder を引く(後述)ので、
この2節でも「id だけ出る構成」「placeholder だけ出る構成」の両方を覆えます。これが重要な
のは、**Android は WebView の版で id と placeholder の出方が入れ替わる**からです。片方だけ
書くと、書かなかった側の構成で「セレクタが見つからない」になります。

## コンテナの型とタイミング

コンテナ自体は `.webView` 型で出ます(`.webView >> …` のスコープ起点にできます)。画面遷移
直後は余裕を持ってください —— 中身が a11y/DOM ツリーに現れるまで数秒かかることがあるため、
WebView 画面へ着地した直後の最初の検証は `timeout:` を長めに取ってください。

## `#x` は placeholder も引く

```swift
type("#email_input", "user@example.com")   // id で一致、無ければ placeholder で一致
```

`#x` はまず `id` の完全一致を試み、**identifier で1件も引けなかったときだけ** placeholder
を試します。つまり `#x` の1節だけでも「id/placeholder のどちらか一方しか出ない」構成を
カバーできます。上の2節形が必要なのは、実行時に構成が揺れて(例: Android の WebView の版)
**両方の可能性**を覆いたいときです。詳細は
[docs/commands.md](../../commands.md)を参照してください。

## Android: WebView の層がスクリーンショットに写らないことがある

Android では、端末のスクリーンショットが WebView の層をまるごと落とすことがあります
(a11y ツリーには全要素が実座標のまま載っているのに、撮った画像だけがその領域が空白になる)。
これは間欠的で、アプリを起動し直すと直ることがあります。そのため**到達確認は
スクリーンショットではなく木のアサーション(`exist` / `notExist`)で書いてください** ——
スクリーンショットに基づく確認は、シナリオ自体とは無関係な理由で失敗することがあります。
スクリーンショットに WebView の中身を写すには、アプリ側で WebView のデバッグが有効である
必要もあります(通常は debug ビルドのみ)。詳細は
[docs/commands.md](../../commands.md)を参照してください。

### Link
- [index](../index_ja.md)
