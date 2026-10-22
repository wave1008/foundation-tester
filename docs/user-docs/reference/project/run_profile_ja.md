# 実行プロファイルの設定項目

[in English](run_profile.md)

`profiles/runs/<name>.json` は、アプリ・デバイス一覧・実行時設定を組み合わせます。
このページでは認識される全キーを一覧します。参照先のアプリプロファイルとデバイスが
自分の居るマシンをどう名乗るかは [profiles_ja.md](./profiles_ja.md)、`--profile` による選択は
[running_scenarios_ja.md](../running/running_scenarios_ja.md) を参照してください。

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "Pixel 9(Android 16, API 36, APIs)-01", "avd": "Pixel_9_Android_16_API_36_APIs_-01" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## キー

| キー | 型 | 既定値 | 意味 |
|---|---|---|---|
| `app` | string | — | 使用する `apps/<name>.json` プロファイル名。そのアプリプロファイルの `platform`(対象 OS)を引き継ぎ、対象外の OS の `devices` は実行時に無視されます([profiles_ja.md](./profiles_ja.md)) |
| `devices` | array | — | 実行するデバイスの実体(同じ配列に iOS/Android を混在可)。各要素: `platform`(`"ios"`/`"android"`、必須)、`machine`(そのデバイスが居るマシン。手元は `"local"`、`fleetest remote machines add` で登録した名前も書ける)、`name`(必須。`machine` と組み合わせて一意。iOS Simulator では Simulator 自身の名前)、`enabled`(`false` なら一覧に残すが走らせない。省略 = 走らせる)、そのデバイス自身の実体キー(`osVersion`/`udid`/`avd`/`serial`/`kind`/`port`/`mode`/`model`。詳細は [profiles_ja.md](./profiles_ja.md)) |
| `heal` | bool | `--profile` 実行は `true`・プロファイル無しの素の `fleetest run` は `false` | セレクタの自己修復(指紋照合方式)を許可する([self_healing_ja.md](../running/self_healing_ja.md)参照)。下記の FM・OCR 系のトグルとは独立(自己修復は FM を使わない) |
| `fmTextVisibilityCheck` | bool | `true` | FM(Foundation Models。experimental — [environments_ja.md](../../overview/environments_ja.md))でテキストの可視性検証をする。詳細は[テキストの可視性検証](../testclass/text_visibility_check_ja.md)。FM が呼ばれるのは、これか `screenLooksLike` が `true` のときだけ |
| `screenLooksLike` | bool | `true` | `screenLooksLike`(FM 視覚検証。experimental — [environments_ja.md](../../overview/environments_ja.md))を有効にする。`false` のときは該当ステップが失敗ではなく skip になる |
| `ocrTextVisibilityCheck` | bool | `true` | 端末の OCR(Vision)でテキストの可視性検証をする。`fmTextVisibilityCheck` と独立で、どちらかが `true` なら視覚検証は走る(両方 `false` なら走らない)。FM が判定を返せないときは、この読みだけで判定する。詳細は[テキストの可視性検証](../testclass/text_visibility_check_ja.md) |
| `preferCheckStateClassifier` | bool | `true` | `checkIsON` / `checkIsOFF` の判定で CheckStateClassifier(プロジェクトの `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に置いた見本画像から学習する画像分類器)をアクセシビリティより優先する。`false` なら、アクセシビリティが状態を報告しない要素にだけ使う。見本画像が無ければ効かない |
| `reportDir` | string | `"reports"` | Markdown レポートの出力先(プロジェクトルート相対) |
| `defaultTimeout` | number(秒) | `5` | `waitSeconds:` を取る DSL コマンドの既定タイムアウト |
| `scenarioTimeout` | int(秒) | `600` | シナリオ単位のホスト側 watchdog(壁時計タイムアウト)。個々のコマンド待ちを縛る `defaultTimeout` とは別物。シナリオに `@Test(scenarioTimeout:)` を書くとそのシナリオだけこちらより優先される(短くする向きも効く)。別に、シナリオの出力が `commandTimeout` の 2 倍を超えて途切れたときもそこで打ち切る(遅いだけで進んでいるシナリオは止めない)。モニターのプロファイルタブ(実行プロファイルの「テスト実行」)の「シナリオの制限時間(秒)」でも設定できる |
| `iosMode` | string | `"inapp"` | `"inapp"` → iOS デバイスは inapp モード(in-app ブリッジ主 + XCUITest ブリッジをフォールバック)で動く。`"xcuitest"` → XCUITest ブリッジのみ。他の値はエラー。`responseMeasurement` の run では既定が `"xcuitest"` になる(計測は XCUITest ブリッジにあるため)。`devices[]` のその要素自身に `mode` を明示していればそちらが優先。Android には影響しない |
| `wipeDataOnBloat` | bool | `true` | 実行開始時、Android AVD の wipe 対象ファイル(userdata/cache/snapshots)が `wipeDataThresholdGB` を超えていたら Wipe Data する。アプリのインストールが容量不足で失敗したときも、そのデバイスを Wipe Data して 1 回だけ入れ直す(`false` のときは Wipe せず、そのデバイスを実行から外す) |
| `wipeDataThresholdGB` | number(GB) | `8` | `wipeDataOnBloat` のしきい値 |
| `updateWebView` | bool | `true` | 実行開始時に端末上の WebView 版を揃える(同じシナリオが端末の WebView 版によって挙動が変わるのを防ぐ) |
| `recoverCpuFallbackToGpu` | bool | `false` | 実行開始時、CPU 描画(swiftshader)へフォールバック済みの Android Emulator を GPU モードで起動し直す |
| `locale` | string | `"ja_JP"` | Android Emulator のブート時に適用するロケール。iOS には影響しない |
| `iosPreActionPing` | bool | `true` | interop WebView 画面(Compose/Flutter 等の埋め込み WebView)でタップ・入力の直前にランナーへ1回問い合わせてから撃つ。attach したままの XCUITest セッションは放置後の座標イベントを成功応答のまま届け損なうことがある。コストは該当画面のイベント1回につき約 +0.4 秒(読み取りと他の画面には掛からない)。inapp モードのときだけ効く |
| `containerInference` | bool | `true` | スクロール容器を幾何から推測する補正(端の見切れ・座標補正等)を有効にする。FM とは無関係 |
| `enableAnimations` | bool | `false` | 実行のためにアプリのアニメーションを無効化せず残す |
| `responseMeasurement` | bool | `false` | **Android か iOS の実機 1 台**を対象にしたレスポンス計測モード。使う有効なデバイス(`--device` で絞った後)が 1 台で、`kind: physical` でなければ run を断る。アプリのアニメーションを残し(`enableAnimations` を強制的に有効)、iOS は xcuitest モードで走らせ、`fmTextVisibilityCheck`・`ocrTextVisibilityCheck`・`screenLooksLike`・`record`・ホスト負荷による減速を止め、run が終わるまでデバイスモニターを止める。`enableAnimations: false` や、`iosMode`(またはデバイスの `mode`)を `inapp`、FM・OCR・`record` のキーを `true` にした併用はエラー。`--broadcast`・`--fleet`・`--split` とは併用できない。[レスポンス計測](../running/response_measurement_ja.md)参照 |
| `responseRepeat` | int | `5` | `responseMeasurement: true` のときだけ指定できます(無しで指定するとエラー)。各シナリオをデバイス上で続けて回す回数で、`1` 〜 `50`。どの回も計測します。結果ファイルは `<id>`、`<id>~2`、`<id>~3`、… の名前で並びます |
| `homeOnStart` | bool | `--profile` 実行は `true`・プロファイル無しの素の `fleetest run` は `false` | 実行開始時に各デバイスへ Home を1回撃つ(一斉起動直後に画面が黒いまま止まるのを防ぐ) |
| `playProtectBypass` | bool | `true` | Android の `adb install` で Play Protect の照会(「アプリをセキュリティ確認のために送信しますか?」)を通さない。インストールの間だけ「USB 経由でアプリを確認」を切って元に戻す(アプリを Google へ送らない)。`false` はキルスイッチ: ツールは端末の設定に触らず、release 署名の APK は端末側のダイアログで止まったままになる(ツールはそのダイアログに答えない) |
| `record` | bool | `true` | 各ワーカーの画面を run 全体で録画し、シナリオごとの clip に切り出す。物理 iPhone は動画を取り出す手段が無いので、最初の操作の直前と、操作したステップ・失敗したステップの直後に撮った画面を時刻どおりに並べた clip になる(コマ送り。撮影1回ごとに約 50ms かかる)。Android の実機は通常どおり録画する。シミュレータ・エミュレータ・Android 実機で画面録画を起動できなかったデバイスも、警告を出してこのコマ送りに切り替える |
| `recordFailuresOnly` | bool | `false` | `record: true` のとき、失敗(frozen 含む)したシナリオの clip のみ残す |
| `recordBitrateKbps` | int | `1000` | 保存する clip の再エンコード bitrate |
| `recordFullResolution` | bool | `false` | `record: true` のとき、半分解像度化をスキップする。テストの所要時間は変わらないが、クリップの容量と、全テストが終わった後のクリップの切り出しの待ちが増える。どちらも画面の動きが多いほど大きい |
| `remoteControl` | object | — | ワークスペースの宣言(`{ "workspace": "<path>" }`)。ワークスペースは常に有効で、省略時は `TestProjects/<プロジェクト>/workspace`。手元の run でもここに `appPath` の原本をステージングし、`scripts/run-setup.sh` / `run-teardown.sh` と `scripts/compose.yaml` をここから読みます。[リモート実行](../../fleet/remote_runners_ja.md) 参照 |

## FM の使われ方

FM(Foundation Models)が呼ばれるのは `fmTextVisibilityCheck` か `screenLooksLike` が `true` の
ときだけです。どちらも既定 `true` です。
両方 `false` の run では FM は一切呼ばれません(FM を一切呼ばせたくない run では両方を `false` に
します)。`fmTextVisibilityCheck` を `false` にしても、`ocrTextVisibilityCheck` が `true` なら可視性検証は OCR だけで
走ります(FM は呼ばれません)。`heal` は FM を使わないため、自分自身のキーだけで制御されます。
自己修復が既定でオンかどうかは実行方法に依存します。**`--profile` を使う実行は `heal` の既定が
ON**、プロファイルを使わない素の `fleetest run` は既定 OFF です。
`fleetest run --profile <name> --set <キー>=<値>` は、プロファイルを書き換えずに1回の
実行だけこの表のほぼどのキーも上書きできます(例: `--set heal=false`・
`--set fmTextVisibilityCheck=false`・`--set reportDir=/tmp/out`・`--set defaultTimeout=8`。
値は上表に示したキーの型と一致させる。複数回指定できる)。`--profile` の有無を問わず効きます —— 例外は実行
プロファイルの devices 一覧・供給工程が要るキー(`iosMode`・`updateWebView`・
`wipeDataOnBloat`・`recoverCpuFallbackToGpu`・`app`・`locale`・
`wipeDataThresholdGB`・`responseMeasurement`・`responseRepeat`)で、これらは `--profile` が必須です。`devices`/`remoteControl` は
配列・オブジェクトなので `<キー>=<値>` の形では指定できません(この2つはプロファイル JSON を
直接編集してください)。`record` は `--profile` か、`--port` を2回以上指定するかのどちらかが要ります(単一接続には録画セッションを付けるところが無いため)。`reportDir` は `--report-dir` と同時指定できません(同じ欄の二重指定になるため)。実行プロファイルのキー `app` はアプリ**プロファイル名**を指し、`fleetest run` の `--app-id` フラグとは別物です。`--set` に未知のキー・型の合わない値を渡すとエラーになります(プロファイル JSON の中の
未知のキーは警告を出して無視されます)。

## iOS のモード

既定の実効モードは `inapp`(in-app ブリッジ主 + XCUITest ブリッジをフォールバックにするハイブリッド構成)です。`iosMode: "xcuitest"`
にすると XCUITest ブリッジのみの実行に切り替わります。iOS の実機も、アプリが**開発署名(get-task-allow)**
なら inapp モードを使えます(注入するブリッジはアプリと同じチームの証明書でツールが署名します)。
開発署名でないアプリ(TestFlight / App Store)は自動で xcuitest モードに縮退します。ランナー機へディスパッチするときは、
ディスパッチする側の Mac がアプリの証明書でブリッジに署名して一緒に送るので、ランナー機に署名の鍵は要りません。

### Link
- [index](../../index_ja.md)
