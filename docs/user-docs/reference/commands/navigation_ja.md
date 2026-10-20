# home, back, appSwitcher, tapAppIcon, rotateTo, fold, unfold, hinge

[in English](navigation.md)

ホーム画面・戻る・アプリスイッチャー・ホーム画面のアイコン・画面回転など OS レベルの操作です。

## 関数

| 関数 | 説明 |
|---|---|
| `home()` | ホーム画面へ移動します。 |
| `back(settle:)` | 前の画面へ戻ります(Android = 戻るキー / iOS = ナビゲーションバーの戻るボタン、無ければ左端エッジスワイプ)。 |
| `appSwitcher()` | アプリスイッチャーを開きます。ホームボタンの iPhone(iPhone SE など)ではスイッチャーがハードのダブルプレスで送れないため、失敗にせず、この step 以降を対象外(skipped)としてシナリオを記録します。 |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンを探してタップします。`name` 省略時はアプリプロファイルの `appName` が使われます。 |
| `rotateTo(.portrait, settle:)` / `rotateTo(.landscape, settle:)` | 画面をその向きへ回します。値はこの2つだけです。 |
| `fold(waitSeconds:)` | 折りたたみ端末を外側の画面へ畳み、デバイスが切り替わったと報告するまで待ちます(上限 `waitSeconds`・省略時は実行の既定タイムアウト)。切り替わらなければ失敗します。 |
| `unfold(waitSeconds:)` | 内側の(大きい)画面へ開きます。ルールは `fold` と同じです。 |
| `hinge(_ degrees)` | ヒンジ角を 0(閉じる)〜180(全開)で設定します。約 130 が半開きのブック姿勢です。どちらの画面が出るかは確かめません。 |

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
fold()                  // 折りたたみ端末のみ
unfold()
hinge(130)              // 半開きのブック姿勢
```

## 注意点

- **`back(settle:)` の確実さは画面によります。** iOS では、システムのナビゲーションバーを持つ画面は
  決定的に戻れますが、フレームワーク独自のナビゲーション(自前描画のナビバー等)を持つ画面は
  エッジスワイプに落ち、これは interactive pop に対応している画面でしか成立しません —
  戻れない画面で `back(settle:)` を撃たないでください(代わりにアプリ内の戻るボタンを `tap()` します)。
  Android では、ソフトキーボードが開いていると1回目の `back(settle:)` はキーボードを閉じるのに
  消費されます(OS の仕様)。入力欄にフォーカスが残っている可能性があるときは2回呼んでください。
- **`tapAppIcon` の探索順**: まず現在の画面を探し、見つからなければ Android はアプリドロワーを
  開いて `flickCenterToTop` で最大8回スクロール、iOS は `flickRightToLeft` で最大5ページ送り
  (2回連続不変化で打ち切り)します。最後まで見つからなければ `"App icon not found.(name)"` で
  失敗します。アイコンは、位置が連続2回の画面読み取りで同じになってからタップします(動いている
  ドロワーやページはタップを飲むため)。アイコンが自分のアプリのものなら、その後アプリが前面に
  来るまで待ち、来なければ(撃ち直さずに)失敗します。
- **`tapAppIcon` は、ホーム画面の木が表示中の画面と一致しないときは撃ちません。** iPhone Duo の Simulator と Xcode 27.2 RC の組み合わせで、内側の画面の配置が木に混ざる事象を確認しています。内蔵画面が2枚の Simulator では木の画面の大きさを表示中の画面と照合し、違えば `the home screen tree reports a … screen but the shown display is …` で失敗します。アイコンの中心が画面の外に載っているときは画面の待ち時間まで読み直し、直らなければ `the home screen reports the icon outside the screen …` で失敗します(当たらない所を撃ちません)。
- **`rotateTo` が契約するのはアプリの UI の向き**であって、実機の傾きではありません —
  シナリオが読む frame はアプリ座標系で、iOS / Android のどの UI フレームワークでも同じ意味で
  振る舞います。値は `.portrait` / `.landscape` の2つだけです(左右の区別はありません)。
- `rotateTo` は向きが実際に変わるまで待ってから返ります。
- **回転を使ったシナリオは終了時に元の向きへ自動で戻ります**(Android は自動回転の設定も
  戻します)。
- **アプリがその向きを許可していないと回りません**(iOS の
  `UISupportedInterfaceOrientations`、Android の `screenOrientation`)。
  Android は前面のアプリがその向きを禁じていれば待たずに失敗し、理由にアプリの宣言を示します。
- このコマンドで回すあいだ、Android は自動回転を切ります(切らないと角度が保持されません)。
- **`settle: false`** を渡すと、このコマンドの操作後の「画面が落ち着くまでの待ち」を省きます(次のステップは動いている最中の画面を見ることがあります)。詳細は [tap](./tap_ja.md) 参照。

- **`fold` / `unfold` / `hinge` は折りたたみ端末が必要です。**
  - iOS: iPhone Duo の **Simulator**(Xcode 27.2 以降)。XCUITest ブリッジ経由で送るので、エンジンは `xcuitest` か `hybrid` にします(`inapp` 単独は不可)。
  - Android: 折りたたみの **Emulator**(ヒンジセンサー付きの AVD。Pixel 9 Pro Fold など)。
  - 物理端末は非対応です(手で畳んでください)。その旨の文言でステップが失敗します。
- **折りたためないデバイスでは、失敗にせず、この step 以降を対象外(skipped)としてシナリオを記録します**(ホームボタンの iPhone での `appSwitcher()` と同じ扱い)。理由は `fold / unfold / hinge need a foldable device (the iPhone Duo simulator or a foldable Android Emulator)` です。
- **折りたたみ状態はシナリオ終了時に自動で元へ戻ります**(`rotateTo` の向きと同じ)。
- **Android の折りたたみ機は、閉じるとアプリの上にロック画面(「上にスワイプで続行」)が出ます。** `fold()` はそれを外してアプリを外側の画面に出してから次へ進みます(画面ロックの解除と同じ操作。PIN やパターンのロックは外せません)。
- **`hinge` はどちらの画面が出るかを確かめません。** iPhone Duo の Simulator は切り替わりが直前の状態に依存します(実測: 開く方向は 120° と 150° の間、閉じる方向は 20° と 10° の間で切り替わる)。折りたたみ Android の Emulator は姿勢が角度の範囲で決まります(Pixel 9 Pro Fold の AVD: 0〜30 が閉じ・30〜150 が半開き・150〜180 が開き)。特定の画面が要るシナリオは `fold()` / `unfold()` を使ってください。
- **iOS の仕組み**: Simulator を畳む公開 API は Apple にありません。fleetest は Xcode の DeviceHub と同じ非公開のヒンジイベントを送ります。将来の Xcode が受け付けなくなる可能性がありますが、`fold` / `unfold` は切り替わりを確かめるので、その場合は黙って通らず失敗として表に出ます。

### Link
- [index](../../index_ja.md)
