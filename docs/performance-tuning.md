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
     - 整定: `CFRunLoopObserver` + 16ms ハートビート。**無限反復アニメ(カーソル点滅等)は
       除外**(数えると settle が cap に張り付く=重要な罠)。
     - **type(テキスト入力): XCUITest 比 1616→~110ms(~15 倍)**。合成タップで対象へフォーカス
       → 現 first responder(UIKeyInput)へ `insertText:`。
     - **ホスト統合: `FTBridgeClient` 無改変**。注入起動済みブリッジを provisioner が
       /status ポートスキャンで発見・再利用し、実シナリオを in-app 経由で駆動できる(keystone)。
     - screenshot: `drawHierarchy` → PNG、45ms。
     **未解決の課題(Phase 3 の残り本丸)**: **合成タップが SwiftUI Button 等の
     ジェスチャ認識器ベースのコントロールを発火できない**。UITextField のフォーカスは
     手動 UITouch+`sendEvent:` で効く(view の touchesBegan/Ended に直接届くため)が、
     gesture 認識器は HID バックのイベントを要求する。試した 3 方式はいずれも不十分:
     ① 手動 UITouch+sendEvent(focus は効くが gesture 不発)② `_setHIDEvent:`+UITouch
     (同上)③ `_enqueueHIDEvent:`(focus すら不発=HID イベントに display-integration
     メタデータが無いと UIKit が破棄)。**次段**: `IOHIDEventSetIntegerValue` で
     `kIOHIDEventFieldDigitizerIsDisplayIntegrated` 等を設定した正しい IOHIDEvent を
     `_enqueueHIDEvent:` に流す(WDA/EarlGrey/KIF の HID 手順を参照)。**これが解ければ
     tap/swipe/press が完成し、シナリオ全体が Android 並み(~2-3s)になる見込み**。
     - 他の残り: ホスト統合の恒久化(シミュ=in-app / 実機=XCUITest の選択、provisioner に
       simctl launch+注入の launch モード追加)、AX 忠実度の詰め(空 TextField の value に
       placeholder が乗る等、XCUITest 版との微差)。
     なお XCUITest の quiescence 自体を私有 API で無効化する案(WDA 方式)は、
     代替の整定信号がプロセス外から得られないため 2 とセットでない限り採らない
- **シナリオ設計の見直し**: 上記 iPhone Air フレークのようなデバイス依存アサーションの排除は、
  どんなエンジン改善より成功率に効く
