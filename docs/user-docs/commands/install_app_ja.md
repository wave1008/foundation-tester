# installApp, removeApp, clearAppData

テスト対象アプリのインストール・アンインストール・データ初期化を行います。

## 関数

| 関数 | 説明 |
|---|---|
| `installApp(path?)` | アプリをインストールします(iOS: `.app` / Android: `.apk` または `.apks`)。パス省略時は実行プロファイルの `appPath` が使われます(明示引数はプロファイルより優先されます)。 |
| `removeApp(id?)` | アプリをアンインストールします。`id` 省略時の解決は `launchApp()` の `bundleID` と同じです。 |
| `clearAppData(bundleID?)` | アプリは残したままデータと権限だけ消します。オンボーディングや権限ダイアログが再び出るようになります。`bundleID` 省略時の解決は `launchApp()` の `bundleID` と同じです。 |

## 例

```swift
installApp()                       // 実行プロファイルの appPath から
installApp("/path/to/MyApp.app")
clearAppData()                     // 初回起動相当の状態に戻す
removeApp()
```

## 注意点

- **入れ直しても権限は戻りません。** iOS シミュレータでは、アプリを削除して再インストール
  しても TCC(位置情報等)の許可が残ったままで、許可ダイアログは再び出ません。「入れ直せば
  初回状態」を前提にしたシナリオは書けないので、権限から戻したいときは `clearAppData()` を
  使ってください。
- **`clearAppData()` は権限(iOS の TCC / Android の実行時権限)も未許可へ戻します**。権限
  ダイアログが再び出るので、オンボーディングや初回起動の権限フローを検証したいときに使います。
- `clearAppData()` は**iOS はシミュレータ専用**です(実機では失敗します)。
- `clearAppData()` は `NSUserDefaults` / `SharedPreferences` を消しますが、**キーチェーン
  (iOS)/ Keystore(Android)に置いた値は消えません**。オンボーディング判定をそこに置いている
  アプリでは初回起動が再現しません。
- **自分自身のテスト対象アプリを `removeApp()` で消すと、以降のシナリオ実行が壊れます** —
  そこでシナリオを終える意図があるときだけ呼んでください。
- **Android では(実機・エミュレータを問わず)、インストールの間だけ `adb install` の検証
  (Play Protect の「アプリをセキュリティ確認のために送信しますか?」)を切り、終わったら端末の
  設定を元に戻します。** テスト対象のアプリが Google へ送られることはありません(release 署名の
  APK は、この検証が有効だとダイアログで `adb install` が止まったままになります。Google Play
  入りのエミュレータでも同じです)。

### Link
- [index](../index_ja.md)
