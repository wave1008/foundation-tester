# 実行プロファイルのキー一覧

`profiles/runs/<name>.json` は、アプリ・デバイス一覧・実行時設定を組み合わせます。
このページでは認識される全キーを一覧します。参照先のアプリ/マシンプロファイルは
[profiles_ja.md](./profiles_ja.md)、`--profile` による選択は
[running_scenarios_ja.md](../running/running_scenarios_ja.md) を参照してください。

```json
{ "app": "sampleapp",
  "devices": [ { "name": "simulator1" }, { "name": "simulator2" }, { "name": "emulator1" } ],
  "fm": true, "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## キー

| キー | 型 | 既定値 | 意味 |
|---|---|---|---|
| `app` | string | — | 使用する `apps/<name>.json` プロファイル名 |
| `devices` | array | — | 実行するデバイス名(解決済みマシンプロファイルから引く。同じ配列に iOS/Android を混在可) |
| `fm` | bool | `true` | FM(Foundation Models)機能全体の親スイッチ。`false` にすると、下記の個別トグルに関わらず自己修復・`falsePositiveCheck`・`screenLooksLike`・失敗時トリアージが一切実行されない |
| `heal` | bool | `true` | FM によるロケータ自己修復を許可する([self_healing_ja.md](../running/self_healing_ja.md)参照) |
| `falsePositiveCheck` | bool | `false` | `exist`/`textIs` 等の偽陽性検証(occlusion guard)を有効にする(既定オフ。FM コストと誤反転リスクのため) |
| `screenLooksLike` | bool | `true` | `screenLooksLike`(FM 視覚検証)を有効にする。`false` のときは該当ステップが失敗ではなく skip になる |
| `reportDir` | string | `"reports"` | Markdown レポートの出力先(プロジェクトルート相対) |
| `defaultTimeout` | number(秒) | DSL 側の既定値 | `timeout:` を取る DSL コマンドの既定タイムアウト |
| `scenarioTimeout` | int(秒) | `90` | シナリオ単位のホスト側 watchdog(壁時計タイムアウト)。個々のコマンド待ちを縛る `defaultTimeout` とは別物 |
| `machine` | string | 自動解決 | 使うマシンプロファイル名の明示指定(解決順序は [profiles_ja.md](./profiles_ja.md) 参照) |
| `iosInappEngine` | bool | `true` | `true` → iOS デバイスは hybrid エンジン(in-app 主 + XCUITest フォールバック)で動く。`false` → XCUITest のみ。マシンプロファイルでデバイスに `engine` を明示していればそちらが優先。Android には影響しない |
| `wipeDataOnBloat` | bool | `true` | 実行開始時、Android AVD の wipe 対象ファイル(userdata/cache/snapshots)が `wipeDataThresholdGB` を超えていたら Wipe Data する |
| `wipeDataThresholdGB` | number(GB) | `8` | `wipeDataOnBloat` のしきい値 |
| `updateWebView` | bool | `true` | 実行開始時に端末上の WebView 版を揃える(同じシナリオが端末の WebView 版によって挙動が変わるのを防ぐ) |
| `recoverCpuFallbackToGpu` | bool | `false` | 実行開始時、CPU 描画(swiftshader)へフォールバック済みの Android エミュレータを GPU モードで起動し直す |
| `locale` | string | `"ja_JP"` | Android エミュレータのブート時に適用するロケール。iOS には影響しない |
| `iosFastInput` | bool | `false` | iOS XCUITest ブリッジのテキスト入力で quiescence 待ちを飛ばす(速いが、動きの激しい画面ではフレークのリスクを伴う)。効くのは XCUITest ブリッジだけ |
| `containerInference` | bool | `true` | スクロール容器を幾何から推測する補正(端の見切れ・座標補正等)を有効にする。FM とは無関係 |
| `enableAnimations` | bool | `false` | 実行のためにアプリのアニメーションを無効化せず残す |
| `homeOnStart` | bool | `true` | 実行開始時に各デバイスへ Home を1回撃つ(一斉起動直後に画面が黒いまま止まるのを防ぐ) |
| `record` | bool | `false` | 各ワーカーの画面を run 全体で録画し、シナリオごとの clip に切り出す |
| `recordFailuresOnly` | bool | `false` | `record: true` のとき、失敗(frozen 含む)したシナリオの clip のみ残す |
| `recordBitrateKbps` | int | `1500` | 保存する clip の再エンコード bitrate |
| `recordFullResolution` | bool | `false` | `record: true` のとき、半分解像度化をスキップする |
| `remoteControl` | object | — | リモート実行のワークスペース宣言(`{ "workspace": "<path>" }`)。[remote_runners_ja.md](../in_action/remote_runners_ja.md) 参照 |

## FM トグルの親子関係

`fm` が親スイッチで、`heal` と `screenLooksLike` は既定 `true`、`falsePositiveCheck` は既定
`false` です。`fm` が `false` なら個別トグルは無効になります。自己修復が既定でオンかどうかは
実行方法にも依存します。**`--profile` を使う実行は `heal` の既定が ON**、プロファイルを使わない
素の `ftester run` は既定 OFF です。コマンドラインの `--heal` / `--no-heal` はどちらの既定も
上書きします(両方の同時指定はエラー)。

## iOS エンジン

既定の実効エンジンは `hybrid`(in-app 主 + XCUITest フォールバック)です。`iosInappEngine: false`
にすると XCUITest のみの実行に切り替わります。iOS の実機はこの設定に関わらず常に XCUITest です
(dylib 注入が実機では使えないため)。

## 廃止されたキー

`iosSystemAlertButtons` はもう読まれません。代わりにシナリオ側の `iosAlertHandler` を使ってください。
[ios_alert_handler_ja.md](../commands/ios_alert_handler_ja.md) を参照してください。

### Link
- [index](../index_ja.md)
