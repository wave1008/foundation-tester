# プロファイル

実行は `TestProjects/<name>/profiles/` 配下の3種類の JSON プロファイルを組み合わせて構成します
(継承ではなく参照による組み合わせです)。

| 種類 | ファイル | 役割 |
|---|---|---|
| アプリプロファイル | `apps/<name>.json` | テスト対象アプリ(bundle ID / パッケージ名、ビルド成果物のパス) |
| マシンプロファイル | `machines/<マシン名>.json` | そのマシンで使えるデバイスの一覧 |
| 実行プロファイル | `runs/<name>.json` | どのアプリ+どのデバイス+実行時設定([run_profile_ja.md](./run_profile_ja.md)参照) |

## アプリプロファイル

`apps/<name>.json` は `common` セクションと `ios`/`android` セクションを後勝ちでマージします
(OS 別セクションが優先):

```json
{ "common":  { "autoInstall": true },
  "ios":     { "appName": "サンプルアプリ", "app": "com.example.sampleapp",
               "appPath": "~/builds/SampleApp.app" },
  "android": { "appName": "サンプルアプリ", "app": "com.example.sampleapp",
               "appPath": "builds/app-debug.apk" } }
```

- `autoInstall` は `common` からのみ読まれます(既定は `appPath` の有無。パスがあってもインストール
  を止めたいときだけ `false` を明示します)。
- `appName`(表示名)・`app`(bundle ID / パッケージ名)・`appPath` は `ios`/`android` セクションに
  書いたものだけが採用されます(`common` に書いても無視されるため、表示名を OS ごとに書き分けられます)。
- `appPath` の相対パスは既定でリポジトリルート基準です(`~` 展開・絶対パスも可)。Android は
  `.apk` のほか `.apks`(App Bundle 由来のスプリット束)も書けます(インストールには
  `bundletool` が要ります)。
- `healthCheckURL`(`common` のみ・任意): 実行開始前に到達確認するバックエンドの URL
  (3秒タイムアウト。不達でも警告だけでブロックしません)。

## マシンプロファイル

`machines/<マシン名>.json` — ファイル名がマシン名になります。1ファイルに、そのマシンで使える
デバイスを `ios` / `android` に分けて列挙します:

```json
{ "ios":     { "devices": [ { "name": "simulator1", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "emulator1", "avd": "Pixel 9(Android 16)" } ] } }
```

- デバイス名は1ファイル内(`ios`/`android` 横断)で一意である必要があります。
- 実機は `"kind": "physical"` と、シミュレータ/AVD 参照の代わりに識別子を書きます。
  iOS は `udid`(`xcrun devicectl list devices` の `hardwareProperties.udid` の形式)、
  Android は `serial`(`adb devices` の左列)です:

```json
{ "ios":     { "devices": [ { "name": "iPhone 実機", "kind": "physical",
                              "udid": "00008130-000A1B2C3D4E5678" } ] },
  "android": { "devices": [ { "name": "Pixel 実機", "kind": "physical",
                              "serial": "14141JEC204922" } ] } }
```

- デバイスの `host` に登録済みのリモートマシン名を書くと、その台は SSH 経由でそのマシンへ
  ディスパッチされます([remote_runners_ja.md](../in_action/remote_runners_ja.md)参照)。
  未指定は「このマシン」を意味します。

`ftester profile setup --auto-device` はデバイスを自動選定します。iOS は最新 OS の既存シミュレータ
(iPad を除く)、Android は既存 AVD のうち API レベルが最大のものを選びます。

## マシン決定の順序

1. 実行プロファイルの `machine` キー
2. 環境変数 `FT_MACHINE`
3. `machines/` にファイルが1つだけならそれ
4. どれも無ければ、候補のマシン名一覧付きエラー

実行プロファイルに書かれた `name` が現在のマシンに定義されていない場合、実行を失敗させず
**スキップ+警告**になります。これにより実行プロファイルをマシン非依存で使い回せます。

## コマンド

| コマンド | 説明 |
|---|---|
| `ftester profile setup --platform <ios\|android\|both> --app-id <id> [--auto-device] [...]` | アプリ/マシン/実行プロファイルをまとめて整合させて作成する(冪等) |
| `ftester profile list` | 実行プロファイルの一覧と、このマシンでの解決結果を表示する |

## VSCode での編集

VSCode 拡張の「デバイス」タブから実行/アプリ/マシンプロファイルを対話的に編集できます。また
`profiles/{apps,machines,runs}/*.json` には拡張が提供する JSON スキーマ(`schemas/*.schema.json`)が
適用され、手で編集する際も補完・ホバー・構造レベルの検証が効きます。詳細は
[vscode-ftester/README.md](../../../vscode-ftester/README.md)(「実行プロファイルの編集支援」)を
参照してください。

### Link
- [index](../index_ja.md)
