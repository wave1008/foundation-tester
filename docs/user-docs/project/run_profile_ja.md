# 実行プロファイルのキー一覧

`profiles/runs/<name>.json` は、アプリ・デバイス一覧・実行時設定を組み合わせます。
このページでは認識される全キーを一覧します。参照先のアプリプロファイルとデバイスが
自分の居るマシンをどう名乗るかは [profiles_ja.md](./profiles_ja.md)、`--profile` による選択は
[running_scenarios_ja.md](../running/running_scenarios_ja.md) を参照してください。

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "emulator1", "avd": "Pixel 9(Android 16)" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## キー

| キー | 型 | 既定値 | 意味 |
|---|---|---|---|
| `app` | string | — | 使用する `apps/<name>.json` プロファイル名 |
| `devices` | array | — | 実行するデバイスの実体(同じ配列に iOS/Android を混在可)。各要素: `platform`(`"ios"`/`"android"`、必須)、`machine`(そのデバイスが居るマシン。手元は `"local"`、`fleetest remote machines add` で登録した名前も書ける)、`name`(必須。`machine` と組み合わせて一意。iOS シミュレータではシミュレータ自身の名前)、`enabled`(`false` なら一覧に残すが走らせない。省略 = 走らせる)、そのデバイス自身の実体キー(`osVersion`/`udid`/`avd`/`serial`/`kind`/`port`/`engine`/`model`。詳細は [profiles_ja.md](./profiles_ja.md)) |
| `heal` | bool | `--profile` 実行は `true`・プロファイル無しの素の `fleetest run` は `false` | セレクタの自己修復(指紋照合方式)を許可する([self_healing_ja.md](../running/self_healing_ja.md)参照)。下記の FM・OCR 系のトグルとは独立(自己修復は FM を使わない) |
| `textVisualCheck` | bool | `true` | `exist`/`textIs` 等のテキストの視覚検証(occlusion guard)を有効にする。木では一致したが実際には見えていない「誤った緑」を検出する。FM(Foundation Models。experimental — [environments_ja.md](../overview/environments_ja.md))が呼ばれるのは、これか `screenLooksLike` が `true` のときだけ |
| `screenLooksLike` | bool | `true` | `screenLooksLike`(FM 視覚検証)を有効にする。`false` のときは該当ステップが失敗ではなく skip になる |
| `ocrTextVisualCheck` | bool | `true` | occlusion guard が FM に訊く前に、端末の OCR(Vision)で要素を読む。期待テキストが丸ごと読めた回は FM を呼ばずに通り、読めなければ従来どおり FM が判定する(切ると同じ検査が遅くなるだけ)。`textVisualCheck` が `false` の run では guard 自体が走らないので効かない |
| `preferCheckStateClassifier` | bool | `true` | `checkIsON` / `checkIsOFF` の判定で CheckStateClassifier(プロジェクトの `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に置いた見本画像から学習する画像分類器)をアクセシビリティより優先する。`false` なら、アクセシビリティが状態を報告しない要素にだけ使う。見本画像が無ければ効かない |
| `reportDir` | string | `"reports"` | Markdown レポートの出力先(プロジェクトルート相対) |
| `defaultTimeout` | number(秒) | DSL 側の既定値 | `waitSeconds:` を取る DSL コマンドの既定タイムアウト |
| `scenarioTimeout` | int(秒) | `90` | シナリオ単位のホスト側 watchdog(壁時計タイムアウト)。個々のコマンド待ちを縛る `defaultTimeout` とは別物 |
| `iosInappEngine` | bool | `true` | `true` → iOS デバイスは hybrid エンジン(in-app 主 + XCUITest フォールバック)で動く。`false` → XCUITest のみ。`devices[]` のその要素自身に `engine` を明示していればそちらが優先。Android には影響しない |
| `wipeDataOnBloat` | bool | `true` | 実行開始時、Android AVD の wipe 対象ファイル(userdata/cache/snapshots)が `wipeDataThresholdGB` を超えていたら Wipe Data する |
| `wipeDataThresholdGB` | number(GB) | `8` | `wipeDataOnBloat` のしきい値 |
| `updateWebView` | bool | `true` | 実行開始時に端末上の WebView 版を揃える(同じシナリオが端末の WebView 版によって挙動が変わるのを防ぐ) |
| `recoverCpuFallbackToGpu` | bool | `false` | 実行開始時、CPU 描画(swiftshader)へフォールバック済みの Android エミュレータを GPU モードで起動し直す |
| `locale` | string | `"ja_JP"` | Android エミュレータのブート時に適用するロケール。iOS には影響しない |
| `iosFastInput` | bool | `false` | iOS XCUITest ブリッジのテキスト入力で quiescence 待ちを飛ばす(速いが、動きの激しい画面ではフレークのリスクを伴う)。効くのは XCUITest ブリッジだけ |
| `iosPreActionWarmup` | bool | `true` | interop WebView 画面(Compose/Flutter 等の埋め込み WebView)でタップ・入力の直前にランナーへ1回問い合わせてから撃つ。attach したままの XCUITest セッションは放置後の座標イベントを成功応答のまま届け損なうことがある(実測 約13% → 暖機で 0/50)。コストは該当画面のイベント1回につき約 +0.4 秒(読み取りと他の画面には掛からない)。hybrid エンジンのときだけ効く |
| `containerInference` | bool | `true` | スクロール容器を幾何から推測する補正(端の見切れ・座標補正等)を有効にする。FM とは無関係 |
| `enableAnimations` | bool | `false` | 実行のためにアプリのアニメーションを無効化せず残す |
| `homeOnStart` | bool | `--profile` 実行は `true`・プロファイル無しの素の `fleetest run` は `false` | 実行開始時に各デバイスへ Home を1回撃つ(一斉起動直後に画面が黒いまま止まるのを防ぐ) |
| `playProtectBypass` | bool | `true` | Android の `adb install` で Play Protect の照会(「アプリをセキュリティ確認のために送信しますか?」)を通さない。インストールの間だけ「USB 経由でアプリを確認」を切って元に戻す(アプリを Google へ送らない)。`false` はキルスイッチ: ツールは端末の設定に触らず、release 署名の APK は端末側のダイアログで止まったままになる(ツールはそのダイアログに答えない) |
| `record` | bool | `false` | 各ワーカーの画面を run 全体で録画し、シナリオごとの clip に切り出す。物理 iPhone は録画できない(`simctl io recordVideo` が無い)ので、そのワーカーについて警告を出し clip は残さない。Android の実機は録画できる |
| `recordFailuresOnly` | bool | `false` | `record: true` のとき、失敗(frozen 含む)したシナリオの clip のみ残す |
| `recordBitrateKbps` | int | `1500` | 保存する clip の再エンコード bitrate |
| `recordFullResolution` | bool | `false` | `record: true` のとき、半分解像度化をスキップする |
| `remoteControl` | object | — | リモート実行のワークスペース宣言(`{ "workspace": "<path>" }`)。[remote_runners_ja.md](../in_action/remote_runners_ja.md) 参照 |

## FM の使われ方

FM(Foundation Models)が呼ばれるのは `textVisualCheck` か `screenLooksLike` が `true` の
ときだけです。どちらも既定 `true`(`textVisualCheck` は 2026-09-03 に既定オフから変更しました)。
両方 `false` の run では FM は一切呼ばれません(FM を一切呼ばせたくない run では両方を `false` に
します)。`ocrTextVisualCheck` は occlusion guard の前段なので、`textVisualCheck` が `true` の
run でだけ効きます。`heal` は FM を使わないため、自分自身のキーだけで制御されます。
自己修復が既定でオンかどうかは実行方法に依存します。**`--profile` を使う実行は `heal` の既定が
ON**、プロファイルを使わない素の `fleetest run` は既定 OFF です。
`fleetest run --profile <name> --set <キー>=<値>` は、プロファイルを書き換えずに1回の
実行だけこの表のほぼどのキーも上書きできます(例: `--set heal=false`・
`--set textVisualCheck=false`・`--set reportDir=/tmp/out`・`--set defaultTimeout=8`。
`--set` については [running_scenarios_ja.md](../running/running_scenarios_ja.md) 参照。
値は上表に示したキーの型と一致させる)。`--profile` の有無を問わず効きます —— 例外は実行
プロファイルの devices 一覧・供給工程が要るキー(`iosInappEngine`・`updateWebView`・
`wipeDataOnBloat`・`recoverCpuFallbackToGpu`・`app`・`locale`・
`wipeDataThresholdGB`)で、これらは `--profile` が必須です。`devices`/`remoteControl` は
配列・オブジェクトなので `<キー>=<値>` の形では指定できません(この2つはプロファイル JSON を
直接編集してください)。`--set` に未知のキーを渡すとエラーになります(プロファイル JSON の中の
未知のキーは警告を出して無視されます)。

## iOS エンジン

既定の実効エンジンは `hybrid`(in-app 主 + XCUITest フォールバック)です。`iosInappEngine: false`
にすると XCUITest のみの実行に切り替わります。iOS の実機はこの設定に関わらず常に XCUITest です
(dylib 注入が実機では使えないため)。

### Link
- [index](../index_ja.md)
