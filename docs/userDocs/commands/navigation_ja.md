# home, back, appSwitcher, tapAppIcon, rotateTo

ホーム画面・戻る・アプリスイッチャー・ホーム画面のアイコン・画面回転など OS レベルの操作です。

## 関数

| 関数 | 説明 |
|---|---|
| `home()` | ホーム画面へ移動します。 |
| `back()` | 前の画面へ戻ります(Android = 戻るキー / iOS = ナビゲーションバーの戻るボタン、無ければ左端エッジスワイプ)。 |
| `appSwitcher()` | アプリスイッチャーを開きます。 |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンを探してタップします。`name` 省略時はアプリプロファイルの `appName` が使われます。 |
| `rotateTo(.portrait)` / `rotateTo(.landscape)` | 画面をその向きへ回します。値はこの2つだけです。 |

## 例

```swift
launchApp()
tap("#settings")
back()                  // 前の画面へ戻る
home()
tapAppIcon()             // アプリプロファイルの名前でアイコンを探してタップ
appSwitcher()
rotateTo(.landscape)
rotateTo(.portrait)
```

## 注意点

- **`back()` の確実さは画面によります。** iOS では、システムのナビゲーションバーを持つ画面は
  決定的に戻れますが、フレームワーク独自のナビゲーション(自前描画のナビバー等)を持つ画面は
  エッジスワイプに落ち、これは interactive pop に対応している画面でしか成立しません —
  戻れない画面で `back()` を撃たないでください(代わりにアプリ内の戻るボタンを `tap()` します)。
  Android では、ソフトキーボードが開いていると1回目の `back()` はキーボードを閉じるのに
  消費されます(OS の仕様)。入力欄にフォーカスが残っている可能性があるときは2回呼んでください。
- **`tapAppIcon` の探索順**: まず現在の画面を探し、見つからなければ Android はアプリドロワーを
  開いて `flickCenterToTop` で最大8回スクロール、iOS は `flickRightToLeft` で最大5ページ送り
  (2回連続不変化で打ち切り)します。最後まで見つからなければ `"App icon not found.(name)"` で
  失敗します。
- **`rotateTo` が契約するのはアプリの UI の向き**であって、実機の傾きではありません —
  シナリオが読む frame はアプリ座標系で、iOS / Android のどの UI フレームワークでも同じ意味で
  振る舞います。値は `.portrait` / `.landscape` の2つだけです(左右の区別はありません)。
- `rotateTo` は向きが実際に変わるまで待ってから返ります。
- **回転を使ったシナリオは終了時に元の向きへ自動で戻ります**(Android は自動回転の設定も
  戻します)。
- **アプリがその向きを許可していないと回りません**(iOS の
  `UISupportedInterfaceOrientations`、Android の `screenOrientation`)。
- このコマンドで回すあいだ、Android は自動回転を切ります(切らないと角度が保持されません)。

### Link
- [index](../index_ja.md)
