# パフォーマンスチューニングガイド

2026-07 の高速化実装(Phase 0〜4)の設計判断・計測方法・調整ノブをまとめた恒久文書。
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
| ワーカー開始のスタガリング | 混在 5 デバイス実測で CPU 平均 50%・launch 衝突スパイクなし | ベンチで launch 時刻と CPU ピークの相関が観測されたら |
| snapshot 差分ポーリング/ポーリング間隔の一律短縮 | 負荷が並列 N 台で掛け算(原則違反) | なし(原則ごと見直す場合のみ) |
| ブリッジ /waitFor(セレクタ条件待ち) | セレクタ解決の Java 複製=二重仕様。整定後は初回ヒットが普通で価値が薄い | exist の初回ミス率が実測で高くなったら |
| HTTP keep-alive | 単一スレッドサーバ+複数クライアント(ライブ+モニター)で飢餓リスク。1接続 8.7ms 実測で効果は数 ms | サーバをマルチスレッド化する大改修をする場合のみ |
| adb forward ポートのファイルキャッシュ | MCP/serve/monitor が常駐でレジストリが効く。残るは稀な CLI 一発のみ | なし |
| 拡張既定バイナリの release 化 | 常駐化でプロセス起動が初回 1 回になり意味消失 | なし |
| capability 交渉・旧タイミング互換モード | バージョン整合は人間担保(ユーザー決定)・単一実装 | なし |
| iOS のシミュレータ私有 IF 直叩き(idb 方式: AXRuntime ツリー+IndigoHID 入力) | snapshot は速くなるが**整定のイベント源が無い**(Android の a11y リスナ相当が無い)ためポーリングに回帰=負荷原則違反。Xcode ベータ毎に壊れるリスクも高い | プッシュ型のアイドル信号を得られる経路が見つかったら |

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
- **アニメーション有効デバイスでは静穏判定後もアニメが画面を動かすため画像が stale になる**
  (a11y要素はFRESHだがscreenshotだけSTALE、という形で顕在化)。ブリッジ起動時に
  window/transition/animator の `*_scale` を自動で無効化する(2026-07-12組込み)。
  実機を追加したときも同様に自動適用される

## 8. 今後の改善候補(価値が出たら)

- **失敗パスの高速化**: 落ちるテストは timeout(5s×箇所)が支配。画面不一致の早期検知や
  タイムアウト時の最終 snapshot 添付(調査 1 往復化)は未実装
- **iOS の高速化ロードマップ(2026-07-12 検討)**: iOS の残り時間は「XCUITest 税」
  = snapshot が毎回 testmanagerd 経由 IPC で全属性取得(~250ms)+イベント合成前の
  暗黙 quiescence 待ち。段階は 2 つ:
  1. **短期(税の減額)= Phase 1 実施済み(2026-07-12)**。3 施策のうち採否が分かれた:
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
     Phase 1 全体の効果は限定的(action 支配項の quiescence ~1s/step は XCUITest 継続の限り残る)。
     **iOS の真のボトルネックは scrollTo(action 中央値 ~7.6s/回。swipe+再 snapshot ループ)と
     tap/type の quiescence 床**であり、大幅短縮には段階 2 が必要と確認された。
  2. **本命(税の撤廃)= Phase 2 プロトタイプで成立を実証済み(2026-07-12)**:
     **アプリ内常駐ブリッジ**(EarlGrey/Espresso と同クラス)。シミュレータは
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
  3. **Phase 3 着手済み(2026-07-12、branch ios-speedup)= `InAppBridge/`**:
     DYLD 注入で対象アプリに常駐し HTTP 応答する in-app ブリッジ。既存 XCUITest 経路
     (`Runner/`)には未接続=**追加のみ**。`build.sh` が `BridgeDTO`(共有)+ in-app 実装 +
     ObjC 構成子を単一 dylib(`InAppBridge/build/libFTInAppBridge.dylib`)にリンク
     (`swiftc -c -wmo`)。9 エンドポイント実装済み(/session は「注入先アプリ一致で OK」、
     lifecycle リセットはホスト再起動が担う)。**動いているもの(実機実証)**:
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
  4. **cross-app ハイブリッド(in-app + XCUITest 併存)= feasibility プロト実証済み(2026-07-12、
     プロトコードは未コミット)**: in-app は同一プロセスしか操作できない(=速さの源泉と表裏)ため、
     「主として sampleapp を in-app で駆動、必要に応じて他アプリ(iOS設定等)やシステム UI も操作」
     には cross-process な XCUITest を**必要な時だけ**併用する。**起動と sampleapp 駆動は in-app のまま
     速く**、XCUITest は既に前面にある画面の操作だけに使う(以前検討した「XCUITest が in-app を起動」
     案とは別。あちらは launch が 4200-5400ms と遅い)。プロトで確認できたこと:
     - **共存**: XCUITest ブリッジ(port A)+ in-app ブリッジ(port B)が同一シミュレータで両方
       /status 応答。**別ポート必須**(同一ポートは bind 衝突)。ただし現行 `scanRunningBridges` は
       port→UDID のみで、同一 UDID に2ブリッジがあると reuse が非決定的 → **/status に `engine` 追加
       →(UDID, engine)で発見**が要る。ハイブリッドデバイスは2ポート消費(8123-8154 で最大16台並列)。
     - **XCUITest cross-app(別フルアプリ)**: `/session com.apple.Preferences` で Settings を
       snapshot/操作可(236ms)。別フルアプリ前面化で sampleapp はサスペンド→in-app 無応答。**復帰は
       `simctl launch <bundleID>`(--terminate 無し)で同一プロセス復帰=注入・状態保持**(XCUITest の
       /session で戻すと再起動され注入が消える)。
     - **ダイアログ・オーバー・アプリ**: sampleapp は前面のまま(in-app 生存)だが in-app からは
       ダイアログ不可視(別プロセス)。**単純な springboard アラート(権限 Allow/Don't Allow 等)は
       XCUITest が「springboard を launch せず参照のみ」の非破壊モードで snapshot+タップ可**(現行の
       /session=launch は springboard を起動しホームに飛んでアラートを消すので不可)。**リッチな
       サービス所有シート(iOS27 写真限定ライブラリ=com.apple.PhotosViewService)は app.snapshot()
       の1アプリツリーモデルでは掴めず未達**。アラート文言はロケール依存なのでセレクタは型(Alert/Button)で。
     **本実装ピース**: ①/status に engine 追加+(UDID,engine)発見 ②2ポート起動 ③XCUITest ブリッジに
     「springboard 非破壊参照」モード ④ルーティング(自動フォールバック=対象が in-app snapshot に
     無ければ XCUITest 経由)。**推奨運用**: フルアプリ切替と単純アラートはハイブリッド、リッチシートや
     確実性重視は `simctl privacy grant`/`defaults write` でダイアログを最初から出さない(Reduce Motion
     自動化と同じ発想)方が安価・確実。
- **シナリオ設計の見直し**: 上記 iPhone Air フレークのようなデバイス依存アサーションの排除は、
  どんなエンジン改善より成功率に効く
