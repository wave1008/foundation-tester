# launchApp, restartApp, terminateApp, openURL

テスト対象アプリの起動・再起動・終了と、ディープリンク URL の配送を行います。

## 関数

| 関数 | 説明 |
|---|---|
| `launchApp(bundleID?, url:?)` | 起動中なら終了してから、あらためて起動します(エントリー画面から始まります)。`url:` を渡すと起動直後にその URL を配送します(配送の詳細は下の `openURL` 参照)。`bundleID` 省略時は既定アプリになります(後述)。 |
| `openURL(url)` | 起動済みのアプリへ URL(ディープリンク)を配送します(**アプリを再起動しません** = warm 配送)。今の画面の上に遷移が積まれます。カスタムスキーム前提です。Universal Links / App Links(`https://`)は AASA/assetlinks.json の取得状態に左右され、シミュレータでは Safari に流れることがあります。 |
| `restartApp(bundleID?)` | 終了してから起動し直します(プロセス内状態のリセットに)。`bundleID` 省略時の解決は `launchApp()` と同じです。 |
| `terminateApp()` | アプリを終了します。 |

## 例

```swift
launchApp()                                  // この run の既定アプリ
launchApp("com.example.myapp")
launchApp(url: "myapp://product/42")         // 新規プロセスで起動してから URL を配送
openURL("myapp://cart")                      // 起動済みのアプリへ配送
restartApp()
terminateApp()
```

## 注意点

- **`launchApp` は起動済みでも前面化ではなく、常にプロセスを終了してから起動し直します。**
  どの呼び出しもエントリー画面から始まります。
- **既定アプリ**(`bundleID` を省略したとき。`launchApp` / `restartApp` / `terminateApp` /
  `removeApp` / `clearAppData` / `appIs` 共通)は次の順で決まります。
  1. `@TestClass(app: "...")` の明示(書いてあればこれが勝ちます)
  2. 実行プロファイルの `app` → アプリプロファイル → 実行中 platform の `ios.app` / `android.app`

  **通常は `app:` を書きません** — 書かなければ同じシナリオが `--profile ios` と
  `--profile android` でそれぞれのアプリを対象に走り、クラスを複製する必要がありません。
  `app:` を書くのは、1プロジェクトに複数アプリのシナリオが混在していてシナリオ側で対象を
  固定したいときだけです。
- **`openURL` はプロセスを再起動しません** — ここが `launchApp(url:)` との違いです(あちらは
  先にプロセスを再起動してから配送します)。アプリが起動済みの状態でディープリンクの着信を
  検証したいときに使います。
- iOS シミュレータでは、あるアプリへの初回の `openURL` 配送時に、OS の確認アラート
  (「"アプリ名"で開きますか?」)が1回だけ出ることがあり、hybrid/xcuitest エンジンではこれを
  自動了承します。以降は端末+アプリの組で同意が永続します。
- 未起動のアプリに `openURL` を撃つと OS がアプリを起動して開きますが、想定用途ではありません。
  cold start の検証自体は in-app エンジンでは表現できません。

### Link
- [index](../index_ja.md)
