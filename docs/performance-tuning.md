# パフォーマンスチューニングガイド

高速化実装の設計判断・計測方法・調整ノブをまとめた恒久文書。
将来チューニングを行う際は、**まず本書の「設計原則」と「不採用の施策」を読んでから**着手すること。
過去に検討済みの案を再発明・再検討する無駄を避けるための文書でもある。

## 1. 経緯と到達点

固定 sleep(シナリオ時間の約 67%)とシナリオ毎の再初期化が支配項だったため、
「待ちはプッシュ型(イベント駆動)、仕事は削減」の原則で置き換えた。実測(2026-07-12):

| 指標 | 改善前 | 改善後 |
|---|---|---|
| Android シナリオ所要(中央値、Android設定アプリ.S0010) | 4.89s | **2.18s(−55%)** |
| iOS シナリオ所要(中央値、3シナリオ×2シミュレータ) | 28.9s | 約21.0s(−27%) |
| ライブ操作のタップ往復(Android) | 0.8〜1.0s | 0.383s |
| snapshot(ブリッジ HTTP 素) | 8.7ms | 変わらず(元々速い) |
| 成功率・ホスト CPU | — | ベースライン同等(悪化なし) |

Android の 2.18s への内訳: 固定 sleep の静穏検知置換で 3.27s(−33%)、さらに
アニメーション自動無効化(§7。GUI E2E で発見したバグの修正の副産物)で 2.18s。
iOS の残り時間は XCUITest 自体のコスト(snapshot 約250ms 等)が支配(§8 の改善候補参照)。

## 2. 設計原則(変更時も維持すること)

1. **並列実行時の負荷を上げない。** エミュレータの CPU=ホストの CPU なので、
   「デバイス側だから無料」は成立しない。待機は必ずプッシュ型(イベント駆動・
   ブロックしたスレッドが通知を待つ形)にする。**ポーリングを速くする方向の
   最適化は禁止**(単発は速くなっても並列 N 台で負荷が掛け算になる)。
2. **単一実装。** フォールバック経路・新旧タイミングの切替モード・プロトコル互換層は
   作らない(2026-07-11 ユーザー決定。adb 直叩きフォールバックと ADBKeyboard は削除済み)。
   バージョン整合はテスト実施者が担保する。
3. **採用ゲートは 3 指標同時。** 速度が上がっても、ホスト CPU か N 回連続成功率が
   悪化する変更は採用しない。固定 sleep は「遅いが負荷ゼロ・フレークを隠す」性質が
   あったので、置換系の変更は特に成功率を疑うこと。

## 3. 現在の時間の内訳(どこを削ると何が起きるか)

シナリオ実行 1 本(Android、改善後 約2.2s)の概観(実測: ステップ所要中央値 444ms、
wait ほぼ 0ms = 固定 sleep の残骸なし):

| 要素 | 目安 | 削る余地 |
|---|---|---|
| アプリ起動(/session: force-stop+monkey+ウィンドウ出現+静穏) | 1〜1.5s | アプリ実起動時間が支配。ほぼ下限 |
| アクション 1 回(注入+静穏待ち+HTTP) | 0.2〜0.5s | 床は QUIET_MS=200ms。下げるとフレーク増と交換 |
| 検証(exist 等、初回ヒット時) | 数十 ms | ほぼ下限(snapshot 8.7ms+パース) |
| サブプロセス初期化(spawn+forward 照会+probe) | 0.15〜0.2s | ランナー常駐化で消せるが見送り中(§6) |

ライブ操作 1 タップ = serve 常駐プロセスへの stdin 1 行 → ブリッジで注入+静穏 →
actionResult+snapshot イベント。0.383s のうち大半は静穏待ちの床(200ms)+snapshot/JPEG。

### 3.1 並列度のスケーリング実測(M1 Max 10コア、2026-07-15)

Demo 16 シナリオ(iOS 6+Android 10)を iOS/Android 同数のデバイスで A/B/C 比較
(全デバイス整定済み・ウォーム状態、runs プロファイルは demo-1x1 / demo-4devices / demo-3x3):

| 構成 | wall(有効な回) | 実行中 CPU idle | 備考 |
|---|---|---|---|
| 1+1 | 98s・98s | 14〜35% | CPU に余裕。並列化の余地あり |
| **2+2** | **57s ×3(ばらつきゼロ)** | 0%(飽和) | **この規模・このマシンの sweet spot** |
| 3+3 | 58s(有効1回) | 0% | 利得ゼロ+3本目ブリッジの供給が不安定(§7) |

- 1+1→2+2 は -42% と素直にスケール。2+2 で 10 コアが飽和するため、3+3 はキュー分割の
  理論利得(iOS 3→2 本/台)が per-scenario の遅延増で相殺され改善しない
- デバイス追加が効くのは「CPU idle が残っている」ときだけ。増やす前に実行中 idle を見る

### 3.2 実行前固定コストの削減(2026-07-15 実装)

シナリオ実行そのもの以外の「実行ボタン→最初のシナリオ開始」の固定コストを3点削減した:

1. **変更なし時の swift build スキップ**(`ScenarioHost.build` + `Sources/FTCore/BuildFingerprint.swift`):
   no-op の `swift build --product` でも SPM の依存グラフ再検証で **~2.6s** かかるため、
   入力(Package.swift/.resolved・Sources/・Scenarios/ の mtime+size+ツールチェーン識別)の
   フィンガープリント一致でスキップする。実測: `api run --dry-run` の連続実行 3.96s → **0.08s**。
   ツールチェーン識別(xcode_select_link の先+version.plist の mtime)を含むのは、Xcode 更新後に
   古いバイナリを温存して FoundationModels ABI 不整合で dyld クラッシュする罠(§CLAUDE.md)を
   スキップが助長しないため。**強制的に再ビルドさせたいときは `.ftester/build-fingerprint-*.txt`
   を消すか手で `swift build` する**
2. **ビルドとワーカー供給の並行化**(`ftester api run`): ビルド(ホスト CPU)とデバイス供給
   (ブリッジ待ち・install)は独立なので、並列実行経路ではワーカー構築 Task を build より先に
   開始する(`ApiRunCommand.run()`)。stderr の供給ログとビルドログは交互に出るようになった
3. **コールド供給のデバイス間並列化**(`BridgeProvisioner.provision`): 「差分判定(並列)→
   プランニング=ポート採番(直列)→ 共有ビルド(直列)→ 起動(デバイス単位で並列)」に分離。
   hybrid の 2 ブリッジは同一シミュレータへの simctl 競合を避けるためデバイス内では従来どおり直列。
   `installIfNeeded` の autoInstall 差分判定(iOS バンドル深比較 / Android md5。アプリサイズ比例)も
   ワーカー単位で並列化。実測: 3 台 hybrid(=6 ブリッジ)の完全コールド(sim ブート+install 込み)
   +ログイン系 3 シナリオ並列で **99s・3/3 passed**(旧直列はデバイス毎に足し算)

効果の出所はあくまで固定費とコールド供給で、ウォームのシナリオ実行本編は不変:
demo-4devices(16 シナリオ・ウォーム・§3.1 と同条件)の実測は wall 55.5/62.0/56.1s
(中央値 56.1s、全回 16/16 passed)で旧コードの 57s×3 と同等、
「実行開始→最初のシナリオ」は旧 ~5.7s(ビルド 2.6s+供給 ~3.1s 直列)→ **3.2s**
(スキップ時。ビルドが要る時も供給と並行なので ≈max(ビルド, 供給))。

### 3.3 devices up(デバイス一括起動)の再設計(2026-07-16 実装)

「デバイスを起動」(`ftester devices up` = `DeviceBooter.bootAll`)の最終仕様:

1. **CPU 負荷ゲートの廃止**(ユーザー決定): 旧実装は毎ブート前に「CPU<90% まで待つ」ゲートが
   あり、最低でも 5 秒窓の計測待ち、負荷が高いと最大 90 秒待った。同時 2 台の固定上限だけで
   CPU はほぼ飽和し暴走もしないため、ゲートごと削除した。
2. **同時進行は最大 2 台・1台ずつ完結**(ユーザー決定): ワーカーは 1 台を「ブート →(iOS)
   ブリッジ供給」まで完結させてから次のデバイスへ進む。**「同時進行が 2 台を超えて見えない」
   こと自体が要件**。ブート完了分を束ねる供給バッチ化(ProvisionBatcher)は demo-3x3 コールドで
   138s→79s と速かったが、供給中デバイス+ブート中デバイスが同時に 3〜4 台進行して見えるため
   撤回した(再検討時は git 履歴のこの日付近傍を参照)。ワーカー間の provision() 同時実行の
   排他は provision() 内の ProvisionLock(flock)が担う。
3. **`api devices-up`(NDJSON)**: 拡張の一括起動はこれを spawn し、`deviceStarting`/
   `deviceFinished` イベントで該当タイルを即「起動中」表示にする(モニターの 2 秒周期スキャン
   の観測を待たない)。タイルのプレースホルダは「待機中(順番待ち)→ 起動中(ブート処理中)→
   接続中(booted・フレーム未着)→ 画面表示」。

cores/3 への同時数自動スケールも実装後に撤回(同ユーザー決定。固定 2)。

### 3.4 devices down(一括終了)の per-device 反映(2026-07-19 実装)

「全て終了」= bulk down のタイルが「全台落ちてからまとめて未起動」になっていた原因と対策:

- **monitor の `pause` はスキャンサイクルごと止める**(フレームだけでなく `determineStates`+
  monitorDevices 送出も止まる。`ApiMonitorCommand` の `if control.isPaused { … continue }`)。bulk down は
  開始時に pause を送る(片付け中デバイスへのスクショ取得で出る過渡的警告を防ぐため。
  `MonitorDeviceOps.monitorPauseDepth`)ので、resume(down 完了)まで各デバイスの offline 遷移が届かず
  最後にまとめて反映されていた。**`suppressFrames` はフレームだけ止めて状態スキャンは継続する別コマンド**
  (pause と混同しない)。タイルの `offline` は monitor 供給の `device.state` 依存。
- 対策: profile 指定の bulk down を **`api devices-down`(NDJSON)** に切替(`Sources/ftester/
  ApiDeviceCommands.swift`)。停止ロジックは `DevicesCommand.Down` の `shutdownProfile` と同一(ios→android
  逐次の `shutdownOne`)で、per-device の `deviceStopping`/`deviceFinished` を足しただけ=回帰なし。拡張は
  `deviceFinished` 受信ごとに **そのタイルだけ offline を先行反映**(`deviceDownFinished` メッセージ →
  `deviceTiles.applyDeviceDownFinished`。monitor は pause のまま=ストリーム再開の競合なし。resume 後の
  devices 反映で本物の state に上書き)。**profile 無しの down は従来の `devices down`**(全ブリッジ停止+
  simctl shutdown all+全 qemu kill の全掃討)のまま=orphan sim/emu も掃討するため。
- イベント形は devices-up と共通(`isDevicesUpEvent`)。契約同期相手: `ApiDevicesDown`(Swift)/
  `monitorDeviceOps.ts` executeBulkJob / `monitorModel.ts` `deviceDownFinished` / `deviceTiles.js`。

## 4. 計測基盤の使い方(チューニングの必須手順)

**変更前にベースライン、変更後に同条件で再計測、summary.md を比較する。**

```bash
# Android 単体(エミュレータ稼働中に)
swift Scripts/bench.swift --project SampleApp --profile android \
  --iterations 5 --scenario Android設定アプリ.S0010 --out bench-results/<名前>

# iOS(プラットフォーム専用シナリオは --scenario で絞る。§7 の落とし穴参照)
swift Scripts/bench.swift --project SampleApp --profile ios --iterations 3 \
  --scenario iOS設定のデバイス画面.S0010 --scenario ログインテスト.S0010 \
  --scenario ログイン画面.S0010 --out bench-results/<名前>
```

- `summary.md` に壁時計中央値/シナリオ毎所要/ステップ所要(durationMs と
  snapshot/action/wait の内訳)/成功率/heal 件数/ホスト CPU・GPU・ANE・MEM が出る
- CPU 計測は `ftester api host-metrics`(デバイスモニターと同一計測系)を内部で流用
- **ANE は FM 介入の検知器**: 決定的実行で ANE が跳ねて heal が 0 件なら、
  失敗時トリアージや screenIs で Foundation Models が動いた証拠(summary が警告する)
- ステップ内訳は NDJSON イベント(`kind:"step"` の `durationMs/snapshotMs/actionMs/waitMs`)
  として流れるので、レポート/拡張からも参照できる
- `bench-results/` は .gitignore 済み。比較対象のベースラインは削除しないこと

### 4.1 ストリーミング vs ポーリングのキャプチャ負荷ベンチ

`Scripts/stream_vs_poll_bench.py`(依存: python3 + 起動中の sim/emu)。デバイス画面配信の2方式
(ストリーミング=`ftester-simstream`/`ftester-androidstream`、ポーリング=`ftester api live serve` へ
`{"cmd":"frame"}` を fps 間隔で送る経路。`monitor.pollingMode` トグルの2方式に対応)のキャプチャ負荷を
静止/モーション × 隣接ベースラインで比較する。

```bash
# 起動中の sim/emu を自動検出、両OS・静止+モーション
python3 Scripts/stream_vs_poll_bench.py
# 片OS・静止のみ・計測窓を延ばして JSON 出力先指定
python3 Scripts/stream_vs_poll_bench.py --platform ios --conditions static --meas 20 --out /tmp/r.json
# 未起動なら device-up して計測(プロファイル名指定)
python3 Scripts/stream_vs_poll_bench.py --boot-ios-name シミュ1 --boot-android-name エミュ1 --project SampleApp
```

- **主指標=キャプチャプロセスの CPU(proc%/core、cputime デルタ/実時間、1コア=100%)**。ホスト差分
  (`host-metrics`、Mac 全体)は 10 コア分母で小信号が ambient 揺らぎ(±3pt)に埋もれるため補助。fps と
  stream_kbps も出す。出力は `bench-results/stream-vs-poll/`(.gitignore 済み)+ 表を stdout。
- 実測(M1 Max / iPhone17Pro sim / Pixel9 emu / fps12・max-width900):静止 proc → ストリーミング **0.2%** /
  ポーリング **~23-26%**、モーション proc → ストリーミング **~5%** / ポーリング **~24%**。fps → ストリーミング
  **~12**(滑らか) / ポーリング **5-8**(スクショ同期往復に律速)。静止でもポーリングは device 側込みで
  host **+14pt**(Android≈1.4コア)を消費。**→ ストリーミングはキャプチャがほぼ無料、特に静止画面
  (モニタの支配的状態)で圧倒的。**
- **H.264+WebCodecs 化後の実測(2026-07-14。上記は MJPEG 経路の値)**: helper モーション時
  Android **5.2%→1.0%**(パススルー化)・iOS **1.5%→0.9%**(VT HWエンコード)、4台デモ65秒平均で
  webview Renderer **8.4%**(MJPEG 時代は瞬時 30-65%)・拡張ホスト 1.4%。このスクリプト自体は
  MJPEG 経路(`--codec` 省略)を測る。h264 の helper 単体は `--codec h264` を付けて同手法で測れるが、
  復号を担う消費側(webview Renderer)は本番パネルでの cputime デルタでしか測れない
- **計測の罠(スクリプト冒頭 docstring に全掲)**:
  - `host-metrics`/`simstream`/`androidstream` は **stdin EOF で即終了**する常駐 CLI。Popen は
    `stdin=PIPE` を開いたまま保持必須(未保持=/dev/null 継承で即死→0 サンプル/0 フレーム。静止 0 と誤診しやすい)
  - ストリーミングは変化駆動で静止は≈0fps(仕様)。負荷はモーション条件でしか見えない
  - ストリーミング helper が 0 フレームでも「壊れた/表示合成が要る」と即断しないこと。simstream は
    **Simulator.app 無し・ヘッドレスでも動く**(実測: 静止≈0fps・モーション≈10fps)。0 フレームの第一容疑は
    上の stdin=PIPE 未保持による即死、次いで静止で変化が無いだけ(モーションを与えて切り分ける)
  - `serve`/`host-metrics` は **cwd=リポジトリルート**で起動(iOS ブリッジ自動起動の repo-root 検出のため)

## 5. チューニングノブ(値を変える場所)

| 定数 | 場所 | 現在値 | 意味・トレードオフ |
|---|---|---|---|
| `QUIET_MS` | AndroidRunner/…/QuietWaiter.java | 200ms | 静穏とみなす無イベント継続時間。下げると速いがアニメーション途中を「整定」と誤判定しやすい。**アクション所要の床** |
| `ACTION_CAP_MS` | 同上 | 2000ms | 静穏しないときの上限(スピナー等の常時アニメ画面で必ず抜けるための安全弁)。整定判定の失敗ではなく打ち切り |
| `LAUNCH_CAP_MS` | AndroidRunner/…/BridgeRouter.java | 10000ms | /session のウィンドウ出現+静穏の上限。超過は 500 エラー(黙って進まない) |
| `STABLE_PACKAGE_BUDGET_MS` | 同上 | 100ms | クロスパッケージ遷移(例: 設定→検索インテリジェンス)で遷移前パッケージを掴む誤整定の防止予算 |
| `RETARGET_EXCLUDED_PACKAGES` | AndroidRunner/…/QuietWaiter.java | {com.android.systemui} | クロスパッケージ遷移時、静穏対象パッケージの追従(TYPE_WINDOW_STATE_CHANGED 検知時に静穏対象を送信元パッケージへ切替)から除外するパッケージ。追従してしまうと遷移先アプリ本体ではなく付随ウィンドウの静穏を待つことになるため |
| `PollBackoff` | Sources/FTCore/PollBackoff.swift | 100→200→400→800→上限1000ms | exist/textIs/ロケータ解決リトライの共通バックオフ。5s timeout での snapshot 回数は旧5回→新8回(許容済み) |
| `defaultTimeout` | FTRuntime(runs プロファイルで上書き可) | 5s | 検証系の待ち上限。失敗するテストの所要を支配 |
| `timeout:`(tap/type/press) | DSL 引数(FTDSL/Commands.swift) | nil | アクションのロケータ解決待ち上限秒。nil=従来の3回リトライ(計700ms)、**0=リトライなし(optional の空振り ~750ms→数十msに短縮する opt-in ノブ)**。遅れて出る要素を拾えなくなるので optional 以外では基本使わない |
| fallback 照会の間引き | StepExecutor.swift(executeAssert) | primary 2回目以降・偶数回ミスのみ | hybrid の SystemUIDriver 照会(springboard 再session+XCUITest snapshot=数百ms)の頻度。実在するシステムUI要素の検知遅れは最大バックオフ1段+1周期 |
| ビルドスキップ判定 | FTCore/BuildFingerprint.swift | mtime+size+toolchain | §3.2。強制再ビルドは `.ftester/build-fingerprint-*.txt` を削除 |
| `ftester.streamCodec` | VSCode 設定(package.json) | h264 | 画面配信コーデック。h264=HWエンコード/デコード(低負荷)、mjpeg=互換(WebCodecs 問題時の退避先。デバイス単位の自動フォールバックあり) |
| 描画間引き(66ms) | vscode-ftester/src/webview/monitor/h264Decoder.js | 約15fps | h264 の canvas 描画間隔。デコード自体は全チャンク必須(P フレーム連鎖)なので下げても復号コストは減らない |
| watchdog しきい値 | vscode-ftester/src/monitorBridgeWatchdog.ts | booted 連続5観測(約10秒)/クールダウン3分/2回で諦め | ブリッジ自動修復の感度。短くすると起動過渡を誤検知、長くすると復旧が遅い |
| `maxConcurrent`(bootAll 引数) | Sources/FTAndroid/DeviceBooter.swift | 2(固定。ユーザー決定 2026-07-16) | devices up の同時進行数(1台=ブート→iOS ブリッジ供給まで)。上限がブートストーム防止を兼ねる(旧 CPU 負荷ゲートは廃止済み。§3.3)。上げると速いがタイルの進行表示も増える |
| GPU 描画モード / 凍結時 CPU フォールバック | DeviceBooter.startEmulator(gpuMode) / ApiDeviceUp `--gpu` / monitorHealthWatchdog | 既定 host / 凍結個体のみ swiftshader_indirect | `-gpu host` は速い(モーション時 約1コア/台)が**画面凍結の主因**(§7)。swiftshader は免疫だが 約3コア/台。全機 swiftshader ではなく、凍結が streamRepair で治らない個体だけ per-device で swiftshader 再起動(セッション中維持。bulk devices-up は host のまま=既知の穴) |

window/transition/animator の `*_scale` はチューニングノブではなく常時 0 固定で、
`Sources/FTAndroid/AndroidBridge.swift` の `startBridge()` 内(ブリッジのコールド起動時)で
自動設定される(§7 参照)。

**ブリッジ(APK)を変えたら `AndroidRunner/build.sh` の VERSION_CODE と
`Sources/FTAndroid/AndroidBridge.swift` の `expectedBridgeVersionCode` を必ず同時に上げる**
(ホストが不一致検出で自動再インストール)。検証時は旧ブリッジを
`am force-stop com.example.ftbridge` してから疎通させると確実。

## 6. 不採用の施策と再検討条件(再発明防止)

| 施策 | 不採用理由 | 再検討条件 |
|---|---|---|
| ランナー常駐化(stdin でシナリオ逐次投入) | 残存コスト ~0.2s/本(全体の1〜6%)に対し、プロトコル+クラッシュ隔離の複雑さが見合わない | ヒール多用ワークロード(FM 3B モデルのプロセス毎再ロードが効く)か、1 バッチ数十本規模 |
| エミュレータ黒画面対策としての Wipe Data / キャッシュ削除の自動化(2026-07-17 精査)→ **同日ユーザー決定で実行プロファイルのオプションとして実装済み** | 精査結論: Wipe Data が効くのは「ブート時黒画面」(Quickboot スナップショット破損・userdata 破損)。本フリートの症状は正常ブート後数分の表示パイプライン凍結で adb reboot で一旦回復する=userdata 破損型と不一致(guest cache.img は 66MB で削除効果なし)。コールドブート保証(`-no-snapshot`。ロード+セーブ無効)を DeviceBooter に実装。**別発見: フリート AVD の userdata-qemu.img.qcow2 が 6〜12GB に肥大**(qcow2 差分は縮まない)。この肥大解消のため、ユーザー決定で実行プロファイルに `wipeDataOnBloat`(既定 true)/`wipeDataThresholdGB`(既定 8。wipe 直後の再構築だけで 2〜4GB になるため 4GB 以下はスラッシング)を追加し、実行開始時に超過 AVD を Wipe Data する(AndroidDataWiper.swift)。**Wipe はゲストを初期化するが、アプリは appPath があれば強制再インストール、ロケールは実行プロファイル `locale`(既定 ja_JP)が再ブート後にブリッジ /locale で自動適用される**(design.md §11.2) | **真因は切り分け済み(2026-07-17): `-gpu host`(§7)。Wipe は凍結には無効で確定** |
| エミュレータ凍結対策としての swangle_indirect(ANGLE/Metal)描画 | 2026-07-17 実測。headless で `screencap -p` が終始 0B(フレームバッファを読めない=証跡取得不能)。GPU アクセラを保ったまま凍結を避ける狙いだったが使い物にならない | emulator が headless での swangle スクショ取得に対応したら |
| iOS ブリッジの実行前プレフライト(シナリオごとの /status 疎通確認) | 2026-07-18 に2実装とも撤去(ユーザー決定)。①「item を取ってから 5s×2 判定→振り直し+離脱」は 10台同時の AX スパイク(一過性の遅さ)で9台一斉離脱・freeze-retry 上限到達の失敗まで発生。②「取る前に 2s 即断+60s 回復待ち」も負荷時の誤判定が残った。**一過性の遅さと本物のウェッジは短い期限では区別できない**。検知は失敗後の事後チェック(bridgeUnreachable 等→振り直し)のみとし、ウェッジ機上の1件が scenarioTimeout(90s)を失うのは許容コスト | XCUITest ランナーが main queue 非依存で /status を返せるようになったら、または iOS 並列度削減で AX スパイク自体が消えたら |
| ワーカー開始のスタガリング | 混在 5 デバイス実測で CPU 平均 50%・launch 衝突スパイクなし | ベンチで launch 時刻と CPU ピークの相関が観測されたら |
| snapshot 差分ポーリング/ポーリング間隔の一律短縮 | 負荷が並列 N 台で掛け算(原則違反) | なし(原則ごと見直す場合のみ) |
| ブリッジ /waitFor(セレクタ条件待ち) | セレクタ解決の Java 複製=二重仕様。整定後は初回ヒットが普通で価値が薄い | exist の初回ミス率が実測で高くなったら |
| HTTP keep-alive | 単一スレッドサーバ+複数クライアント(ライブ+モニター)で飢餓リスク。1接続 8.7ms 実測で効果は数 ms | サーバをマルチスレッド化する大改修をする場合のみ |
| adb forward ポートのファイルキャッシュ | MCP/serve/monitor が常駐でレジストリが効く。残るは稀な CLI 一発のみ | なし |
| 拡張既定バイナリの release 化 | 常駐化でプロセス起動が初回 1 回になり意味消失 | なし |
| capability 交渉・旧タイミング互換モード | バージョン整合は人間担保(ユーザー決定)・単一実装 | なし |
| iOS のシミュレータ私有 IF 直叩き(idb 方式: AXRuntime ツリー+IndigoHID 入力) | snapshot は速くなるが**整定のイベント源が無い**(Android の a11y リスナ相当が無い)ためポーリングに回帰=負荷原則違反。Xcode ベータ毎に壊れるリスクも高い | プッシュ型のアイドル信号を得られる経路が見つかったら |
| ライブ操作の SCK(ScreenCaptureKit)フレーム配信(DeviceHub/Emulator ウィンドウをキャプチャ、実装後ユーザー判断で撤回) | 実装は完動した(較正=ブリッジ実スクショとのテンプレートマッチ、~30fps)がキャンセル。実装時の実測知見: ①多数フレームワークをリンクした大型 CLI(ftester 本体)から SCK を呼ぶと macOS 27 beta で replayd 接続が再接続ストームになり await が無期限ブロック(Task.sleep も不発)→小型 @main 単体バイナリへの隔離が唯一の安定解 ②CLI からは NSApplication.shared(CGS 初期化)が先に必須 ③captureImage は要求キャンバスへスケールせず実効スケールで左上描画+透明パディング→倍率は不透明領域境界から検出する ④非表示ウィンドウへの captureImage はエラーでなくブロック=isOnScreen 必須 ⑤解像度は画面上のウィンドウサイズ依存(原寸スクショより低い) | 高fpsのライブ映像が再び必要になったら(実装の骨子はこの行と git 履歴のこのコミット前後を参照) |
| エミュレータの Vulkan 有効化(`-feature Vulkan`)と HWUI の skiavk 化(guest UI 描画を GLES→Vulkan へ) | 2026-07-14 A/B 済(emulator 36.6 / Pixel 9 A16 / -gpu host)。**`-gpu host` の時点で gfxstream+host Vulkan(MoltenVK)は既定で有効**(起動ログ `vulkan_mode_selected:host`)のため `-feature Vulkan` は実質無操作。残る HWUI skiavk 化(`setprop debug.hwui.renderer skiavk`、Pipeline=Skia (Vulkan) 確認済)も同一スワイプ10回の qemu CPU が 10.6s→11.1s と改善なし(むしろ微増) | emulator が Apple Silicon で HWUI Vulkan を既定化したら、または ANGLE 変換(GLES→Metal)がプロファイルで支配的と実測されたら |
| デバイス側動画ストリーミング(iOS=simctl recordVideo、Android=screenrecord/scrcpy + ffmpeg。2026-07-14 の当初 spike で不成立。ただし iOS はその後 ftester-simstream で成立→理由欄の追記参照) | **追記(2026-07-14以降): iOS のヘッドレス映像ストリーミングは別方式で成立済み**(`ftester-simstream`=CoreSimulator/SimulatorKit の private API `SimDisplayIOSurfaceRenderable` の IOSurface を `setPowerState:1` で起こし、フレーム単位に JPEG 化して長さ前置で stdout へ。simctl でも ffmpeg でもないため下記の不成立要因を構造的に回避。ヘッドレス=Simulator.app 非起動で mid-run・ネイティブ解像度・静止時ほぼ0fps を実測確認。ライブ操作タブ+デバイスモニタータブの両方で採用。実装: `Sources/ftester-simstream/main.m` / `vscode-ftester/src/deviceStream.ts` / `monitorDeviceStreamController.ts`。**「iOSストリーミングは不可能」と誤読しないこと**)。**以下の「不成立」は simctl recordVideo と ffmpeg パイプ方式に限った当初 spike の結果**。画像取得ポーリングの負荷対策として検討し、その2方式は両OSとも不成立だった。**iOS**: `simctl io recordVideo` は stdout(`-`)を「rendering to standard out is no longer supported」で拒否、ファイル/FIFO 出力も非フラグメント(moov を SIGINT 時に確定書き込み、`has_moof: False`)=録画停止まで1フレームも復号不可。**Android**: `adb exec-out screenrecord --output-format=h264 -` の生H.264を **ffmpeg にパイプ入力すると EOF まで出力をバッファしライブ逐次フレームが出ない**(実測: 同じH.264をファイル入力なら41フレーム復号できるがパイプ入力は mid-run 0。`-flush_packets1`/`-threads1`/`-use_wallclock_as_timestamps`/`-avioflags direct`/`-fflags nobuffer -flags low_delay`/fps有無/mpjpeg・image2pipe・image2個別ファイル の約16構成すべて mid-run 0。adb はパイプへ逐次配信済=adb 原因ではない。ffmpeg はライブ入力 lavfi なら逐次フラッシュするので raw-h264 パイプ demux の仕様的限界)。scrcpy 録画→FIFO(mkv)もクラスタバッファでライブ不可(frame=0)。**採用した代替=ライブの frameTick を旧 delayMs=0 ホットループから `ftester.liveFps`(既定12)頭打ちに変更**(iOS/Android 共通・依存ゼロ・負荷源そのものを解消) | **iOS は ftester-simstream で解決済み(理由欄の追記)。以下は Android 向け**: Android で真の映像ストリーミングが必要なら **GStreamer 未検証**(`fdsrc ! h264parse ! avdec_h264 ! jpegenc` はライブパイプ前提設計で ffmpeg のバッファ問題が無い可能性)。ただし heavy dep(`brew install gstreamer`)の再導入になる |

## 7. 既知の落とし穴(ベンチ・検証時)

- **iOS設定のデバイス画面.S0010 は iPhone Air に割り当たると決定的に失敗する**
  (PHOTOS_UPLOAD_DEVELOPER_MODE スイッチが Air では OFF というシナリオ設計起因)。
  N=3 のベンチ成功率が揺れるのはこのデバイス割当のくじ引き。高速化の回帰と混同しないこと
- runs プロファイルに片 OS のデバイスだけ指定すると、他 OS 専用シナリオは
  スキップされず失敗扱いで実行される。ベンチは `--scenario` で対象を絞る
- VSCode 拡張の monitor / host-metrics 常駐プロセスは、バイナリ再ビルド後も
  旧バイナリのまま生き残り、ベンチの CPU を汚したり旧ブリッジを自動再起動したりする。
  計測・APK 更新検証の前に Reload Window するか手動 kill する
- ブリッジは単一スレッドなので、整定待ち中(最大 2s)はモニターの /screenshot が
  順番待ちになる(ベストエフォート表示のため許容している。仕様)
- `UiAutomation.setOnAccessibilityEventListener` は**1 枠しかない**。QuietWaiter が
  使用中なので、別用途でリスナが必要になったら QuietWaiter 経由で多重化すること
- 長時間ベンチ中の画面ロックに注意(GUI E2E 全般の既知問題)
- **フォールバック検証の偽陽性(緩和済み)**: hybrid でシステム UI を tap するとき、セレクタの
  label が in-app の要素 label の**部分文字列**だと primary(in-app)が `contains` で誤解決し得た。
  現在は tap アクション経路で **primary が部分一致(substring)止まりなら fallback を照会し、
  fallback に完全一致(exact)があれば fallback を優先**する(`StepExecutor` の resolveDetailed/
  matchDetailed。primary が exact のときは fallback を照会せずコスト増なし)。ただし `exist()` 等の
  アサーション経路は従来どおり(部分一致の存在確認は許容)なので、確証が要るときは
  **同一シナリオを engine=inapp(フォールバック無)でも走らせ当該 tap が失敗することを確認**
  (negative control)。
- **通知許可ダイアログのリセットは `simctl privacy` では効かない**(あれは TCC=写真/連絡先等)。
  通知権限は**アプリ再インストール(uninstall→install)でのみ未決定に戻る**。ダイアログ系の
  fixture を繰り返し検証するときは各回 reinstall する
- **アニメーション有効デバイスでは静穏判定後もアニメが画面を動かすため画像が stale になる**
  (a11y要素はFRESHだがscreenshotだけSTALE、という形で顕在化)。ブリッジ起動時に
  window/transition/animator の `*_scale` を自動で無効化する(2026-07-12組込み)。
  実機を追加したときも同様に自動適用される
- **常駐 CLI は stdin EOF で即終了する**(`ftester api {host-metrics,live serve,monitor}`、
  `ftester-simstream`、`ftester-androidstream`。拡張は stdin パイプを開いたまま保持している)。
  アドホックに spawn して計測・検証するとき、stdin を /dev/null 継承のまま渡すと即座に EOF を検知して
  終了し、0 サンプル/0 フレームになる(静止時の 0 と区別がつかず「helper が壊れた」と誤診しやすい)。
  子プロセスの stdin は開いたまま保持すること(`subprocess.Popen(..., stdin=PIPE)` で閉じない等)
- **タイル黒+「接続中/ブリッジ応答なし」が続く=ブリッジ死を疑う**(XCUITest ランナーの HTTP
  サーバだけ死んで xcodebuild 親が残ることがある。実例: 2026-07-14)。確認は
  `curl -m 3 localhost:<port>/status`、復旧は `ftester devices up --profile <名>`
  (死んだポートだけ再供給される)。拡張のウォッチドッグが自動修復するが、
  `ftester.autoRepairBridge` を OFF にしている場合や CLI 単独運用ではこの手順で
- **稼働中デバイスへ simstream/androidstream を並走 spawn して計測しない**(本番ストリームが
  不安定化し、webview の codecError→mjpeg フォールバックやストリームのギブアップを誘発した実例
  あり)。ヘルパー単体のベンチはモニターが掴んでいないデバイスで行う
- **「CPU 100% 張り付き+GPU は暇」はエミュレータのソフトウェア描画(SwiftShader)を疑う**。
  判定は `adb shell dumpsys SurfaceFlinger | grep GLES:`(SwiftShader なら CPU 描画、
  `Apple M1 ...(Metal)` なら host GPU)。DeviceBooter は `-gpu host` 起動で対策済みだが、
  手動起動のエミュレータや AVD 設定変更で再発しうる(headless では hw.gpu.mode=auto が
  SwiftShader に落ちる)
- **画面凍結(白フレーム固着)の真因は `-gpu host` + headless + macOS 27 / emulator 36.5.10**
  (切り分け実測 2026-07-17)。症状: ゲストは健全(`mWakefulness=Awake`・screen ON・adb/a11y/入力可)
  だが `screencap`/`screenrecord` が一様白(PNG 10-16KB)を返す。起動後 0〜3 分でランダム発生、
  約25秒周期でフラッピングする個体もある。**切り分け手順**(再発時の検証テンプレ): 空き AVD を
  `emulator -avd X -port P -no-window -no-snapshot -gpu <mode>` で直接起動(モニターのプロファイル外=
  stream されない)し、GPU モードだけ変えて同一ホスト・同一負荷で `screencap -p | wc -c` を比較。
  実測: host は screenrecord 有無問わず凍結、swiftshader_indirect は約20分健全。**readback(screencap/
  screenrecord)は真因でなく不安定な緩和**(アイドル host 機は readback ゼロだと確実凍結、readback で
  一時回復するが高負荷下では screenrecord 稼働中でも再凍結する)。根治は GPU モード変更(§5・§6・
  design.md §12.3)。対処: 凍結個体だけ swiftshader へ per-device フォールバック(design.md §12.4)
- **シミュレータのコールドブート直後は Spotlight インデックスが計測を汚す**: 設定トップに
  「検索とSiriを最適化中」行(id=com.apple.settings.spotlightIndexingProgress)が挿入され、
  CPU も食う(負荷下ではタイムアウト失敗を誘発。完了まで10分超の個体もある)。ベンチ前の
  整定ゲートは「設定トップの snapshot からこの id が消えるまで」で判定できる
- **エミュレータの初回コールドブートはゲスト内スワップで数分間激遅**(2GB AVD+Play サービスの
  学習ジョブ等。1シナリオ約3分の実例)。ホスト側 qemu CPU% は低くても遅い(メモリ/IO バウンド)。
  判定は `adb shell top` の Swap 使用と idle%、または1シナリオのプローブ実行(正常なら数秒)
- **シミュレータの表示名重複はブリッジ再利用のマッチングを壊す**(/status の device はシミュレータ
  表示名のため)。同名機が居ると毎回新規ブリッジ起動→供給タイムアウトの連鎖になる。
  `simctl rename` で一意にする
- **失敗が特定シミュレータ個体に集中したら(タップ後の画面遷移が起きない等)、その個体の再起動を
  先に試す**(shutdown→boot で解消した実例。セレクタや負荷を疑う前に個体差を除外する)
- **XCUITest ブリッジの3本目以降は負荷下で供給タイムアウトしやすい**。タイムアウト後に遅れて
  ready になり、次回の実行で「稼働中ブリッジを再利用」して成功する(=1回おきに成功・失敗が
  交互になったらこのパターン)。恒常的に3台以上の iOS 並列を使うなら供給タイムアウト延長か
  供給の直列化を検討(§8)。※この実測は供給が直列だった時代のもの。2026-07-15 の並列供給化
  (§3.2)後は無負荷コールドの 3 台 hybrid(6 ブリッジ)は成立を確認済みだが、負荷下の挙動は
  未再計測(悪化しうる方向なので交互パターンを見たらまずここを疑う)

- **iOS ブリッジのウェッジ(接続は受けるが無応答)の診断手順**: ① `curl -s -m 2 -o /dev/null -w "%{http_code}" http://localhost:<port>/status` で 000 なら無応答(200 が健全。ポートは 8123〜)。② run が固まって見えるときは `lsof -p <run pid> | grep ESTAB` — ブリッジポートへの ESTABLISHED が動かないのは無応答待ち。③ `sample <pid> 2` で全スレッドが workq/mach_msg でパーク+CPU 0% なら「返らない await」(死活確認系は withDeadline 必須。design.md §12.4)。復旧は `ftester bridge down --port <N>` で該当だけ停止(次の供給が作り直す)
- **XCUITest ランナーの起動 ≈25〜30s/本はビルドではなくセッション確立コスト**(`xcodebuild test-without-building`=ランナー .app の sim へのインストール+XCTest セッション確立+/status 応答まで。共有ビルドはキャッシュで通常 no-op)。さらに供給は ProvisionLock(クロスプロセス flock、ポート採番の bindFailed(48) 対策)で直列化されるため、**壊れたブリッジが多いと run 開始が 10s→70〜80s 化する**。健全なフリートなら再利用スキャン(2s タイムアウト)だけで 1〜2s
- **iOS 10台同時のシナリオ第一波で AX スパイクが起き、健全なブリッジも数秒〜数十秒 /status に応答しなくなる**(2026-07-18 実測: 一斉離脱後の計測で 12本中11本が 200=一過性)。短い期限の死活確認はここで誤判定する(§6 プレフライト不採用の根拠)
- **Swift 構造化並行の罠: `withTaskGroup`+`cancelAll` はキャンセルに応答しない子タスクの完了を待つ**。ウェッジ機への URLSession(120s/リクエスト)を子に持つと、期限側が勝っても遅い方を待ち続けて run 全体が凍結する(実測: 全スレッドパークで5分以上)。死活確認の期限は「先着確定レース+遅い方は放置」(RunOrchestrator.withDeadline)にする

## 8. 今後の改善候補(価値が出たら)

- **iOS 並列度の上限設定(実行プロファイル)**: ブリッジウェッジの根本原因は 10台同時の AX スパイク
  (シナリオ第一波で健全ブリッジも無応答化)。振り直し・復帰は対症療法なので、実行プロファイルに
  iOS 同時実行数の上限(例: 6〜8)を足してスパイク自体を減らすのが本筋。ウェッジ頻度が実測で
  下がるかで判断する

- **失敗パスの高速化**: 落ちるテストは timeout(5s×箇所)が支配。画面不一致の早期検知や
  タイムアウト時の最終 snapshot 添付(調査 1 往復化)は未実装
- **iOS ブリッジ供給の堅牢化(3台以上の並列時)**: ランナーのコールドスタートが負荷下で
  供給タイムアウトを超え、run 全体が中断する(§7 の交互成功パターン)。候補: タイムアウト値の
  負荷連動延長、ランナー起動の直列化、タイムアウト後も起動継続中なら待ち直す再確認ループ。
  現状 2 台までは安定しているため優先度低(3.1 の実測により 2+2 が sweet spot で、
  3 台以上を常用する動機も当面ない)
- **iOS の「XCUITest 税」と高速化エンジン**: XCUITest 経路の残り時間は「XCUITest 税」
  = snapshot が毎回 testmanagerd 経由 IPC で全属性取得(~250ms)+イベント合成前の
  暗黙 quiescence 待ち。施策は 2 系統:
  1. **税の減額(XCUITest 経路内)**。3 施策のうち採否が分かれた:
     - ✅ **Reduce Motion 自動設定**(採用): `BridgeLauncher.enableReduceMotion()` が
       コールド起動時のみ `simctl spawn <device> defaults write com.apple.Accessibility
       ReduceMotionEnabled -bool true` を実行(Android の `disableAnimations()` の対称)。
       doctor に警告も追加(`animationScaleWarning` の iOS 版)。設定は以後起動される
       アプリに効くため /session がシナリオ毎に再起動する前提で有効。リスクゼロ・原則整合。
     - ✅ **/type の固定待ち削除**(採用): 旧 `usleep(400_000)`。当初 `keyboards.firstMatch.
       waitForExistence(timeout:1)` に置換したが**逆効果で不採用**(シミュレータのキーボードは
       別プロセス扱いで `app.keyboards` クエリが常にタイムアウト = type 中央値 1616→2248ms に
       悪化。2026-07-12 実測)。**最終解は待ちを完全削除**(`coordinate.tap()` が既に
       quiescence まで待つため後続 `typeText` は安定)。type 中央値 1616→1387ms(−230ms)・
       5 連続入力成功・成功率 100%。
     - ❌ **snapshot の私有パラメータ絞り込み**(不採用): `snapshotWithParameters:error:`
       (maxDepth 等)は Xcode 27 beta 3 に実在し呼び出しも成功したが、**速度改善が実測ゼロ**。
       設定アプリのルート画面で有効要素が深さ 21 前後に集中しており、取りこぼさない安全な
       深さ上限(≥32)では削れるノードが無い。warm snapshot は元々 80〜90ms で
       ボトルネックでもない(遅く見えた 250ms 平均は初回/画面遷移直後の一過性)。
       私有 API 依存 + Xcode ベータ毎に壊れるリスクだけが残るため採用ゲート不通過。
       **再検討条件**: 要素数が数百規模の巨大画面が現れ、warm snapshot が実測で
       ボトルネックになったら(そのとき maxChildren/maxArrayCount の方が効く可能性)。
     税の減額の効果は限定的(action 支配項の quiescence ~1s/step は XCUITest 継続の限り残る)。
     **iOS の真のボトルネックは scrollTo(action 中央値 ~7.6s/回。swipe+再 snapshot ループ)と
     tap/type の quiescence 床**であり、大幅短縮には税の撤廃(下記2)が要る。
  2. **税の撤廃 = アプリ内常駐ブリッジ**(EarlGrey/Espresso と同クラス)。シミュレータは
     `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<dylib> simctl launch` で任意アプリに
     リビルドなしで注入できる(シミュレータプロセスは SIP/hardened runtime 非適用)。
     UIKit ビュー階層の直接走査(ms 級・IPC ゼロ)+ランループオブザーバと
     CATransaction/CADisplayLink による**真のイベント駆動整定**+プロセス内タッチ合成。
     既存 9 エンドポイントの HTTP 互換にすればホスト側は概ね無変更(単一実装原則と整合)。
     **3 点プロトタイプの実測結果**(SampleApp・iPhone 17 Pro シミュレータ、Xcode 27 beta 3):
     - 注入: `__attribute__((constructor))` の dylib が確実にロード、`connectedScenes`→
       `windows` から UIKit 階層を走査可能(accessibility ラベルも取得可)。
     - snapshot: プロセス内フル走査(ラベル/フレーム/enabled 収集込み)が **0.058ms/回**
       (XCUITest の warm 80〜90ms・cold 250ms に対し 3〜4 桁高速)。IPC 撤廃の効果。
     - 整定: `CFRunLoopObserver`(kCFRunLoopBeforeWaiting)で「アイドル 2 連続 かつ
       全レイヤ `animationKeys` 空」を整定判定。300ms アニメを **319ms・ポーリング 5 回**で
       検知(ビジーループなし=Android QuietWaiter の iOS 版)。XCUITest の保守的な
       暗黙 quiescence(~1s/action)を置換できる。
     - タッチ: 合成タップ(`UITouch` + `[app _touchesEvent]` + `sendEvent:`。`setWindow:`
       `_setLocationInWindow:resetPrevious:` `setPhase:` 等の private セレクタは Xcode 27
       beta 3 に実在)だけで、`becomeFirstResponder` を呼ばずに対象 UITextField が
       first responder 化(実イベントパイプラインが駆動)。`IOHIDEventCreateDigitizerFingerEvent`
       も dlsym 可能で代替経路として使える(EarlGrey/KIF がシミュレータで長年使う経路)。
     - Swift dylib: 単一 dylib に Swift `.o` + ObjC 構成子(`@_cdecl` を呼ぶ)を
       リンクすれば Swift でも注入可・UIKit アクセス可。→ リポジトリの `BridgeHTTPServer`/
       `BridgeDTO`(Foundation 依存のみ)を再利用できる。
     見込みは Android 並み(シナリオ ~2s 級)。制約: 実機は注入不可
     (自ビルドアプリへのリンク方式のみ)、タッチ合成に私有 API を使う。
     **XCUITest ランナー(Runner/)は実機用として残す**(ユーザー決定 2026-07-12)=
     単一実装原則の明示的な例外として「シミュレータ=in-app / 実機=XCUITest」の 2 経路を許容。
  3. **in-app ブリッジの実装(`InAppBridge/`)**:
     DYLD 注入で対象アプリに常駐し HTTP 応答する in-app ブリッジ。`build.sh` が `BridgeDTO`(共有)+ in-app 実装 +
     ObjC 構成子を単一 dylib(`InAppBridge/build/libFTInAppBridge.dylib`)にリンク
     (`swiftc -c -wmo`)。9 エンドポイント実装済み(/session は「注入先アプリ一致で OK」、
     lifecycle リセットはホスト再起動が担う)。**実装(実機確認済み)**:
     - snapshot: `UIAccessibility` API で AX ツリー走査 → `ElementInfo`(DTO 完全互換)。
       起動時に **`_AXSSetAutomationEnabled(YES)`** で AX を活性化(XCUITest 相当。しないと
       `accessibilityFrame` が zero・label 空で全要素が落ちる)。フレームは `view.convert
       (bounds, to: nil)` で堅牢化。0.03〜0.06ms/回。
     - 整定: `CFRunLoopObserver` + 16ms ハートビート(キーウィンドウのみ対象)。**除外必須の
       アニメ2種**: ①無限反復(カーソル点滅・スピナー)②**iOS27 Liquid Glass の装飾モーフ**
       (`CASDFElementLayer`/`_UILiquidLensView` の `match-*`/`punchout`。タブバー等が常時走らせる)。
       いずれも数えると settle が cap(2500ms)に張り付く=**重要な罠**。除外後は遷移も 100〜250ms で収束。
     - **type(テキスト入力): XCUITest 比 1482→~500ms**(合成タップでフォーカス→ first responder
       (UIKeyInput)へ `insertText:`。合成タップの focus は view の touchesBegan/Ended に直接届く)。
     - **tap: `accessibilityActivate()`(VoiceOver ダブルタップ相当=要素のデフォルトアクション発火)**。
       これが決定打。**合成タッチ(UITouch+sendEvent / `_setHIDEvent:` / `_enqueueHIDEvent:` の
       5方式)はいずれも SwiftUI Button 等のジェスチャ認識器を発火できなかった**(HID の
       display-integration メタデータを完全再現できず。focus は効くが gesture 不発)。
       snapshot が ref→AX 要素を保持し、tap(ref) はその要素を activate する。座標指定(x/y)も
       直近 snapshot の point を含む最小要素を activate(SwiftUI の活性化要素は合成 AX ノードで
       hitTest の view 階層に無いため、hitTest+祖先 activate では発火しない)。活性化不能な要素は
       合成タッチにフォールバック。XCUITest 比 767→~280ms。
     - **swipe: `UIScrollView.setContentOffset` 直接操作**(スクロールのジェスチャ認識器も合成タッチで
       駆動できないため。面積最大の可視 `UIScrollView` を探し contentOffset を ±可視領域 85% 動かす。
       `accessibilityScroll` は SwiftUI List で片方向しか効かず不安定だったので不採用。双方向スクロール
       を実機確認済み)。無い場合は合成スワイプにフォールバック。
     - **press: 合成タッチ(down→ランループ保持→up)で動作**(意外にも tap/swipe と違い長押し
       ジェスチャは発火する。保持中に gesture 認識器が touch を処理するため)。コンテキストメニュー
       (SwiftUI `.contextMenu`)を開き、メニュー項目を accessibilityActivate でタップする完全フローを
       実機確認済み。
     - screenshot: `drawHierarchy` → PNG、45ms。
     - **ホスト統合(engine 選択+lifecycle)= 完成**: machine プロファイルのデバイスに
       `engine`("xcuitest" 既定 / "inapp")を持たせ、`engine=inapp` のときサブプロセスが
       `InAppDriver`(launch=simctl 再起動+dylib 注入、他は HTTP で `BridgeClient` へ委譲)を使う。
       provisioner は注入起動済みブリッジを /status スキャンで発見・再利用、不足分は
       `InAppLauncher`(注入起動)で起動。**ホスト実行系(`FTBridgeClient`/RunOrchestrator/
       ScenarioHost)は engine フィールドを通すだけで概ね無改変**。
       **engine=inapp の新規ブリッジ起動には注入対象アプリの bundleID が要る**(run プロファイルの
       apps.ios.app 経由でのみ得られる)。無い場合は XCUITest にフォールバックせず**明示エラー**
       (`inAppNeedsBundleID`。単一実装・フォールバックを作らない方針。device/live 等 bundleID を
       渡さない経路は engine=inapp 非対応)。稼働中ブリッジ再利用時は launch しないので bundleID 不要。
     **実シナリオ実証(ログイン画面.S0010、実機)**:
     - 単発(warm・状態リセット無し): step 合計 ~11.0s(XCUITest)→ **~3.0s(3.7倍速)**。
     - **プロファイル経由 3 イテレーション: 全 passed=True**(以前は 2 回目以降ログイン済みで失敗)。
       各イテレーションの launch = `InAppDriver` の simctl 再起動+注入 **~2900ms**(fresh 状態確保。
       XCUITest の launch 4200〜5400ms より速い)。step 合計 ~6.2s(XCUITest ~11s の 1.6倍速)。
       **XCUITest 経路(engine 既定)は回帰なし・FTCore 143 テスト全パス**。
     残り時間の内訳: launch(fresh 起動)2.9s + シナリオ自身の明示 wait(1s)+ 別プロセスの
     システム UI(パスワード保存シート「今はしない」)への optional タップ空振り(~750ms)。
     エンジンの実操作(type/tap/exist)は合計 ~1.1s。
     **AX id 忠実度=解決済み**: 当初 `.accessibilityIdentifier` を拾えず id 単独セレクタが
     解決不能だったが、原因は `as? UIAccessibilityIdentification` キャスト(SwiftUI の
     `AccessibilityNode`/`UIKitTextField` はセレクタに応答するがプロトコル準拠を宣言しない)。
     **セレクタ直接呼び出し(`FTAccessibilityIdentifier`)に修正して解決**。`ログインテスト.S0010`
     (`#email`/`#password`/`#login_error` 等の id 単独セレクタ+relaunchApp+エラーパス+textIs)が
     in-app 経由で passed=True。
     **軽微項目=すべて解決**: (a) 空 TextField の value に placeholder が乗る微差 → 実テキスト(.text)が
     空なら value=nil に修正(非空 SecureTextField は accessibilityValue のマスクを維持し実パスワードは
     晒さない)。(b) press → 実機確認済み(上記)。(c) 並列複数 in-app デバイス → シミュ1-inapp(8123)+
     シミュ2-inapp(8124)で 2 シナリオ並列全 passed(port/udid 配線が並列で正しい)。install 前注入起動の
     順序は engine=inapp+autoInstall のとき注入起動が install より先に走る(現状はアプリ事前 install が
     必要=エラーメッセージで案内)。
     なお XCUITest の quiescence 自体を私有 API で無効化する案(WDA 方式)は、
     代替の整定信号がプロセス外から得られないため 2 とセットでない限り採らない
  4. **cross-app ハイブリッド(in-app 主 + XCUITest フォールバック)**: `engine=hybrid` を指定すると in-app(主・高速)で駆動し、対象要素が
     in-app snapshot に無いとき **XCUITest(システム UI)へ自動フォールバック**する。in-app は
     同一プロセスしか見えない(=速さの源泉と表裏)ので、既に前面にあるシステム UI(権限ダイアログ等)
     だけ XCUITest に委ねる。「XCUITest が in-app を起動」案とは別(あちらは launch 4200-5400ms と遅い)。
     - **配線経路(同期が必要)**: `BridgeProvisioner`(hybrid は in-app + xcuitest の2ブリッジを起動、
       `ProvisionedIOSDevice.xcuiPort`)→ `DriverConnection.xcuiPort` → `ScenarioHost` が `--xcui-port`
       で伝搬 → `ScenarioRunnerMain` が `SystemUIDriver(port:)` を構築 → `StepExecutor.fallbackDriver`。
     - **フォールバック解決**(`StepExecutor.executeAction`/`executeAssert`): 主 driver(in-app)の
       poll(最大3回)で解決できないとき **fallbackDriver.snapshot() で1回だけ**解決を試し、当たれば
       以降の act をその driver で行う。**注意: フォールバックは snapshot 1回のみ(poll しない)**。
       遅延して出るダイアログはシナリオ側で `wait` を入れる(通知許可等は `.action` に `wait(2)`)。
     - **ブリッジ発見**: `/status` に `engine`("inapp"/"xcuitest")を追加し、`scanRunningBridges` は
       (UDID, engine) で照合(同一 UDID に2ブリッジが共存するため port→UDID だけでは reuse が非決定的)。
       ハイブリッドデバイスは2ポート消費(8123-8154 で最大16台並列)。旧ブリッジは engine=nil→"xcuitest" 扱い。
     - **springboard 非破壊参照モード**(`BridgeRouter.handleLaunch`): bundleID=com.apple.springboard の
       とき `target.launch()` せず参照だけ張って snapshot/tap 可。**launch すると springboard がホームに
       飛びアラートを消す**ので不可。`SystemUIDriver.snapshot()` は毎回 springboard を再 session(refs を
       張り直す)が、tap/press は再 session しない(refs が消える)。
     - **実機 A/B 検証済み**: 通知許可ダイアログ(springboard 別プロセス、in-app 不可視)に対し
       `tap("許可||Allow")` が **hybrid=passed(fallback label=Allow で解決)/ inapp=failed(ロケータ
       解決不可)**。同一アプリ・同一手順・唯一の差はフォールバック driver の有無 → フォールバック経路が
       働いた確証。既存 `ログインテスト.S0010` も hybrid で全 passed(通常シナリオに非回帰)。
       **アラート文言はロケール依存**(この個体は英語 "Allow"/"Don't Allow")。
     - **シナリオ単位の自動ルーティング**(ScenarioRunnerMain のドライバ構築): シナリオの対象アプリ
       (`@TestClass(app:)`)が in-app 注入先(in-app /status の sessionBundleID)と**異なる**とき、
       hybrid はそのシナリオを**丸ごと XCUITest ブリッジで駆動**(iOS設定アプリ等のシナリオが既定 ON でも
       動く)。engine=inapp(明示)は明示エラー。**この分岐が無いと別アプリの注入起動がポート衝突で
       旧ブリッジの偽成功応答になり「裏のアプリを操作して失敗」する**(E2E で実際に発生)。
     - **suspend 時のルーティング(2026-07-15 修正。混在実行の必須対策)**: 上記ルーティングは in-app
       /status の応答に依存するが、**直前に別アプリ(system-UI)シナリオが走ると iOS が背面へ回った
       注入先アプリを suspend し、in-app ブリッジは TCP は受理するが HTTP 応答を返さなくなる**
       (pre-flight プローブが既定 45s ハング=「ドライバに接続できません: The request timed out」)。
       対策: プローブは短タイムアウト(`BridgeClient.status(timeout:)` 4s)にし、**無応答時は provision
       時の注入先 bundleID(`DriverConnection.inappBundleID` → `ScenarioHost` が `--inapp-app` で伝搬)を
       注入先とみなして**分岐する(対象==注入先 → InAppDriver、別アプリ → XCUITest)。**無応答を一律
       InAppDriver に倒すと、suspend 中の別アプリ(Preferences 等)シナリオを in-app 経路へ誤ルーティング
       して破綻する**(この誤りで実際に回帰し、Preferences シナリオがハング → §design 8.8 の
       `waitUntilExit` 凍結で run 全体が固まった)。InAppDriver 経路は pre-flight `status()` を省略する
       (suspend でハングし、かつ冒頭 launchApp の注入 relaunch で bridge を必ず張り直すため不要)。
       混在させないなら `iosInappEngine=false`(全 XCUITest)で回避もできる。
     - **未達**: リッチなサービス所有シート(iOS27 写真限定ライブラリ=com.apple.PhotosViewService)は
       app.snapshot() の1アプリツリーモデルでは掴めない。**推奨運用**: 単純アラートはハイブリッド、
       リッチシートや確実性重視は `simctl privacy grant`/`defaults write` でダイアログを最初から出さない
       方が安価・確実。**シナリオ途中の deliberate フルアプリ切替(sampleapp 操作中に設定アプリへ遷移等)
       は対象外**(フォールバックは「アプリ前面のまま出るシステム UI」向け。シナリオ丸ごと別アプリは
       上記ルーティングで XCUITest が担う)。
     - 使い方(推奨): **run プロファイルの `iosInappEngine`(既定 true=ON。GUI「高速なinappエンジンを
       使用する(iOS)」チェックボックス)で選ぶ**。ON → iOS デバイスの実効エンジンを "hybrid"、OFF →
       "xcuitest"(`ProfileResolver.resolve`)。マシンプロファイルの device に `engine` を明示していれば
       そちらが優先(上書きしない=pure "inapp" 固定などの逃げ道)。`engine=inapp` 同様 bundleID 必須
       (新規 in-app 起動に要る。`inAppNeedsBundleID`)。**既定 ON なので engine 無指定の iOS デバイスは
       ハイブリッドで走る**(従来 XCUITest だった `ios.json` 等も高速化。XCUITest に戻すには OFF)。
- **シナリオ設計の見直し**: 上記 iPhone Air フレークのようなデバイス依存アサーションの排除は、
  どんなエンジン改善より成功率に効く
