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
  1. **短期(税の減額)**: ① Reduce Motion の自動設定
     (`simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled 1`。
     Android のアニメーション無効化の対称。iOS ブリッジ起動時に自動化)
     ② snapshot の取得属性・深さの絞り込み(XCUITest 私有パラメータだが
     WebDriverAgent/Appium で長年の実績。250ms→100ms 級が相場)
  2. **本命(税の撤廃)**: **アプリ内常駐ブリッジ**(EarlGrey/Espresso と同クラス)。
     シミュレータは `simctl launch` の `DYLD_INSERT_LIBRARIES` で任意アプリに
     リビルドなしで注入できる(シミュレータプロセスは SIP/hardened runtime 非適用)。
     UIKit ビュー階層の直接走査(ms 級・IPC ゼロ)+ランループオブザーバと
     CATransaction/CADisplayLink による**真のイベント駆動整定**+プロセス内タッチ合成。
     既存 9 エンドポイントの HTTP 互換にすればホスト側は無変更(単一実装原則と整合)。
     見込みは Android 並み(シナリオ ~2s 級)。制約: 実機は注入不可
     (自ビルドアプリへのリンク方式のみ)、タッチ合成に私有 API を使う。
     **進め方**: 1 を実施・計測 → 不足が残る場合のみ 2 を snapshot/tap/整定の
     3 点プロトタイプで実測してから本実装を判断(Phase 2 級の大工事のため)。
     なお XCUITest の quiescence 自体を私有 API で無効化する案(WDA 方式)は、
     代替の整定信号がプロセス外から得られないため 2 とセットでない限り採らない
- **シナリオ設計の見直し**: 上記 iPhone Air フレークのようなデバイス依存アサーションの排除は、
  どんなエンジン改善より成功率に効く
