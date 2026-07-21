# PoC: 自作ドライバ vs Appium 性能比較ベンチマーク

実施日: 2026-07-21 / ブランチ: `poc/appium-driver-benchmark`

## 目的

foundation-tester のドライバを自作した効果を定量化するため、ドライバ層だけを Appium に
差し替えて同一シナリオの実行性能を比較する。追補として、典型的な Appium Java Client の
使い方を再現した変種(appium-java)と、可能なチューニングを全て適用した変種(appium-tuned)
も計測した(§追補)。

## 比較の設計(何を固定し、何を差し替えたか)

`AppDriver` protocol(Sources/FTCore/AppDriver.swift)が唯一の差し替え点。DSL・セレクタ解決
(matchDetailed)・シーン進行・整定待ち・レポートはすべて共通のまま、ドライバ実装のみを
3種類切り替えた。したがって差はドライバのトランスポート/スナップショット取得方式の差を反映する。

| エンジン | 実装 | 経路 |
|---|---|---|
| hybrid(自作 in-app) | InAppDriver | ホスト → アプリ内常駐 HTTP サーバ(dylib 注入)が UIKit ツリーを直接読む/イベント直接注入 |
| xcuitest(自作ブリッジ) | BridgeClient | ホスト → XCUITest ランナー内蔵 HTTP サーバ → XCUITest API |
| appium(PoC 実装) | AppiumDriver | ホスト → Appium サーバ(Node)→ WebDriverAgent(XCUITest)→ XCUITest API |

Appium ドライバは本 PoC で新規実装(`Sources/FTBridgeClient/AppiumDriver.swift` +
`AppiumSource.swift`)。W3C WebDriver HTTP を直接叩き、既存アーキテクチャと同じ設計
(スナップショット1回/ステップ+ホスト側セレクタ解決+座標タップ+セッション常駐再利用)で
組んである。注意: 当初この方式を「Appium 経路の下限」と推定していたが、本物の Java Client での
追試(§追補2)により **per-action は findElement 方式の方が速い**(スナップショット全取得は
1ステップあたり約2倍のコスト)ことが判明した。snapshot 方式が買っているのは set-of-mark 参照・
FM 自己修復・画面全体の文脈であり、速度ではない。

## 環境・手法

- マシン: M2 Ultra(ライブモニターがフリート5台で並行稼働中。負荷は全エンジンに等しくかかる)
- デバイス: ベンチ専用シミュレータ iPhone 17 Pro(iOS 27.0)を新規作成(フリートと分離)
- 対象アプリ: SUT Store(com.sutec.mobile、Compose Multiplatform 製)
- Appium 3.5.2 / appium-xcuitest-driver 11.13.0 / Node 26
- シナリオ 4本(タブナビゲーション 25 step・カート追加 15 step・検索絞り込み 8 step・
  ログイン入力バリデーション 3 テスト 29 step。type を含むのはログインのみ)
- 各エンジン warmup 1 回(セッション作成・ブリッジ供給・初回起動コストを除外)+ 計測 5 回
- エンジンブロック間で XCUITest ランナー(自作ブリッジ/WDA)を掃除(同居させると競合するため)
- 計測は NDJSON の step イベント(`durationMs` / `snapshotMs` / `actionMs` / `waitMs`)と
  ハーネス側 wall time。**失敗ラン 0 / 60 計測ラン**
- launch の意味論は3エンジンとも「再起動」に統一(考察の知見4参照)

## 結果1: シナリオ単位(中央値 / 平均 ± 標準偏差、秒)

| シナリオ | エンジン | wall(s) | step計(s) | うち snapshot(s) | うち action(s) |
|---|---|---|---|---|---|
| タブナビゲーション(25 step) | hybrid | **7.3** / 7.7 ± 0.9 | 4.9 | 0.3 | 1.6 |
| | xcuitest | 13.2 / 13.2 ± 0.0 | 10.4 | 1.1 | 4.7 |
| | appium | 20.9 / 20.9 ± 0.1 | 19.1 | 8.6 | 6.1 |
| カート追加(15 step) | hybrid | **7.3** / 7.7 ± 1.1 | 4.7 | 0.1 | 0.9 |
| | xcuitest | 11.2 / 11.2 ± 0.1 | 8.5 | 0.6 | 2.2 |
| | appium | 14.0 / 13.9 ± 0.1 | 12.5 | 4.2 | 2.8 |
| 検索絞り込み(8 step) | hybrid | **4.7** / 4.7 ± 0.1 | 3.2 | 0.1 | 0.7 |
| | xcuitest | 8.0 / 8.0 ± 0.1 | 6.6 | 0.5 | 1.5 |
| | appium | 9.9 / 9.9 ± 0.0 | 9.5 | 3.3 | 1.9 |
| ログイン入力(3テスト・29 step) | hybrid | **17.6** / 17.6 ± 0.1 | 15.8 | 1.1 | 7.1 |
| | xcuitest | 26.9 / 26.9 ± 0.1 | 24.6 | 1.0 | 9.6 |
| | appium | 34.7 / 34.7 ± 0.3 | 31.9 | 9.7 | 9.1 |

**シナリオ全体で appium は hybrid の 1.9〜2.9 倍、自作 xcuitest ブリッジの 1.25〜1.6 倍の所要時間。**

## 結果2: 操作単位(step durationMs 中央値)

| 操作 | hybrid | xcuitest | appium | appium/hybrid 比 |
|---|---|---|---|---|
| tap(#id、代表: タブ切替) | **110〜125** | 375〜440 | 700〜985 | 約 7× |
| exist(テキスト/#id の存在確認) | **4〜15** | 27〜57 | 180〜525 | 約 30〜50× |
| type(12〜19 文字) | **820〜1,217** | 769〜1,326 | 1,009〜1,656 | 約 1.3× |
| launch(アプリ再起動) | **2,273〜2,364** | 4,622〜4,711 | 4,335〜4,361 | 約 1.9× |
| wait 1.0s(固定待ち・対照) | 1,065 | 1,065 | 1,055 | 1.0×(=計測系は公平) |

- wait(固定待ち)が3エンジンで一致していることが、計測装置自体の公平性の裏付け。
- appium の内訳: tap ≈ snapshot(`GET /source` 250〜500ms)+ W3C Actions(約 460ms)。
  exist ≈ snapshot のみ。Appium サーバ(Node)での JSON→WDA プロキシ往復が各コマンドに乗る。
- hybrid の tap ≈ アプリ内スナップショット(数ms〜)+ イベント直接注入(約 100ms)。
- 自作 xcuitest ブリッジは同じ XCUITest 基盤ながら appium の約半分。中間サーバが無いことと、
  スナップショットがフィルタ済み JSON(要素上限 120)で XML 全ツリーより軽いことによる。

## 結果3: 定常外コスト(warmup で観測、参考値)

| 項目 | hybrid | xcuitest | appium |
|---|---|---|---|
| 初回セッション/ブリッジ確立 | 数秒(dylib 注入起動) | 10〜20s(ランナー供給) | 35〜60s(WDA ビルド済みでもセッション作成 30s 前後) |
| セッションの永続性 | アプリ内常駐(アプリ死で消滅) | ランナー常駐 | Appium サーバ+WDA 常駐(newCommandTimeout=0) |

## 考察: 自作ドライバの効果

1. **アサーション密度が高いほど自作(in-app)が効く。** exist は 30〜50 倍差。CAE 構造で
   expectation を厚く書く本ツールの設計では、この差がシナリオ全体の 2〜3 倍差に直結している。
2. **XCUITest を残した自作ブリッジでも Appium の約 1.3〜1.6 倍速い。** 「Appium をやめて
   ランナーを直接持つ」だけで得られる分と、「in-app 化」でさらに得られる分は分離して評価できる。
3. **安定性**: 全エンジン失敗ゼロ・±0.3s 以内で再現。ドライバ差は平均値の差であり、フレーク差は
   このシナリオ集合では観測されなかった。
4. **意味論の罠(PoC 実装で実際に踏んだもの)**: Appium 統合では
   (a) xcuitest ドライバに `mobile: type` が無い(findElement+sendKeys に変更)、
   (b) `GET /source` は JSON ラップされた XML、
   (c) サーバ上のセッション記録だけ生き残り WDA が死ぬと「生存」誤判定でプロキシ全滅
   (`/window/rect` での実往復プローブ+`could not proxy command` の失効扱いで解決)、
   (d) `activateApp` は「前面化」であり既存エンジンの launch(再起動)と意味論が異なる
   (直前シナリオのキーボードが残りセレクタ解決が壊れる実害)——という4件の実害バグを踏んだ。
   自作ドライバはランナーまで自前のためこの種のプロトコル齟齬が構造的に発生しない。

## Appium 側に残る利点(公平性のための注記)

- クロスプラットフォーム(本 PoC の AppiumDriver も iOS/Android 両対応で書いてある。Android=
  UiAutomator2 は未計測)、実機・クラウドファーム対応、エコシステム・人材。
- 本ツールの自作ランナー(XCUITest ブリッジ/Android instrumentation)は OS・Xcode 更新への
  追従保守が必要。Appium はそれをコミュニティが負担する。
- ベンチの appium 数値は「本ツール流の使い方」での下限に近い。逆に言えば、既存の Appium 資産を
  このハーネス(スナップショット1回+座標タップ+セッション常駐)に載せ替えるだけでも従来型
  クライアントよりは大きく速くなる、という読み方もできる。

## 制限

- iOS シミュレータのみ(Android エンジン配線は実装済みだが未計測)。1 アプリ・小さめの画面ツリー
  (source XML 約 14KB)。ツリーが大きいアプリでは `/source` 依存の appium が更に不利になる見込み。
- appium-xcuitest-driver の設定チューニング(waitForIdle 系など)は既定のまま。
- ホストでライブモニター(別件5台)が並行稼働。全エンジンに等しく乗る負荷であり比較には影響しない
  が、絶対値は静かなマシンより悪い可能性がある。

## 再現手順

```
# Appium サーバ起動(別ターミナル)
appium server --port 4723

# ベンチ(3エンジン × 4シナリオ × warmup+5)
python3 Scripts/poc-appium-bench.py <出力dir> 5
python3 Scripts/poc-appium-aggregate.py <出力dir>
```

実行プロファイル: `Projects/sut-ec-mobile/profiles/runs/ios-poc-{hybrid,xcuitest,appium}.json`
(専用マシンプロファイル `machines/LDIPC96-poc.json`)。appium 切替は実行プロファイルの
`"engine": "appium"`(または machines 側 `DeviceSpec.engine`)。

## 追補: Java Client 再現(appium-java)と全チューニング適用(appium-tuned)

「PoC の appium は本物の Java Client より速すぎる」という疑問に答えるため、2 変種を追加計測した
(短縮ベンチ: warmup 1 + 計測 2)。

| 変種 | セッション | tap | チューニング |
|---|---|---|---|
| appium-java | **シナリオ(=テストクラス)毎に新規作成**(@BeforeClass 相当。quit で WDA が死に毎回コールドブート) | findElement → 要素スコープ click | なし(Java Client 既定相当。newCommandTimeout=60) |
| appium-tuned | 常駐再利用(appium と同じ) | 座標(W3C Actions) | usePrebuiltWDA・wdaLocalPort 固定・**waitForIdleTimeout=0 / animationCoolOffTimeout=0** |

注: appium-java(Swift 製エミュレーション)は §追補2 の本物 Java Client により妥当性検証を終えた後、
**コードからは撤去済み**(本節の数値は撤去前の実測記録)。以後の Java Client 計測は
`Scripts/poc-appium-javaclient/` を使う。

### 結果(wall 中央値・秒)

| シナリオ | hybrid | xcuitest | appium | appium-tuned | appium-java 実測 | 〃1セッション換算* |
|---|---|---|---|---|---|---|
| タブナビ | **7.3** | 13.2 | 20.9 | 20.5 | 174.2 | ≈ 96 |
| カート追加 | **7.3** | 11.2 | 14.0 | 13.5 | 166.2 | ≈ 89 |
| 検索絞り込み | **4.7** | 8.0 | 9.9 | 9.6 | 162.1 | ≈ 86 |
| ログイン(3テスト) | **17.6** | 26.9 | 34.7 | 32.6 | 337.6 | ≈ 262 |

\* ハーネス都合で appium-java の実測 wall には WDA ウォームアップ用の余分なセッション1回が
含まれる(単一テストシナリオで計2回、ログインで計4回)。「1テストクラス=1セッション」の実運用
相当に補正した参考値 = step計 + セッション1回あたり実測コスト×クラス数。

### セッション作成コストの分解(マイクロベンチ: create を交互に3回ずつ)

| 条件 | 実測 |
|---|---|
| 素の caps(クリーン成功時) | **37.0s** |
| 素の caps(状態誤認バグのリトライ込み) | 73.6〜73.7s |
| usePrebuiltWDA + wdaLocalPort | 73.4〜77.7s(**改善なし**) |

- 真のセッション作成コスト ≈ **37〜50s**(本環境: フリート並走負荷+beta ツールチェーン。
  静かなマシン+安定版では一般に 10〜30s 程度が相場で、本環境は重い側)
- 残り ≈ 25s は appium-ios-simulator の状態誤認バグ(「Simulator is not in 'Shutdown' state」
  15s タイムアウト+5s リトライ)による「バグ税」。シナリオ実行から逆算した 76s/セッションと一致
- usePrebuiltWDA が効かないのは、ビルドは元々差分キャッシュ済みで、支配項が WDA ランナーの
  ブートとバグ税のため。**構造的に効く対策は「セッション使い回し」と「WDA 事前起動
  (webDriverAgentUrl)」の2つだけ**
- セッション quit で WDA(xcodebuild)が道連れで終了し、次セッションで必ずコールドブートに
  なることが「Java Client は遅い」の体感の主因

### チューニングの効き(appium vs appium-tuned)

waitForIdleTimeout=0 / animationCoolOffTimeout=0 の効果は本アプリでは **2〜7% 改善に留まる**
(tap 中央値はほぼ不変)。対象アプリが静的(アニメーション・常時通信が少ない)ため XCUITest の
整定待ちが元々発生しておらず、per-action の支配項は Appium サーバ経由の往復と /source 取得。
アニメーションが多いアプリではこの差は開く可能性がある。

### appium-java の per-action(参考)

tap 862ms(findElement+element.click。座標タップ 800ms 比 +8%)/ exist 335ms / type 1,467ms。
per-action は appium と同オーダーで、**Java Client の遅さの本体は per-action ではなくセッション
ライフサイクル**であることが確認できた。

### 追補の結論(※3 は追補2の本物 Java Client 実測で更新)

1. 実運用の Java Client(セッション毎作成)は本環境で hybrid の **12〜19 倍**(1セッション換算)。
   体感「Appium は遅い」は主にセッションライフサイクル起因で、per-action の差とは別建てで
   考えるべき
2. Appium 側でできる最大のチューニングは「セッション使い回し」。設定系チューニング
   (waitForIdle 等)の上積みは本アプリでは数%
3. ~~自作ドライバの優位(2〜3倍)は、チューニングし尽くした Appium に対しても残る~~ →
   本物 Java Client の実測(§追補2)により更新: snapshot 方式の本 PoC appium は Appium の
   下限ではなく、**findElement 方式+セッション使い回し(java-tuned)なら自作 XCUITest ブリッジと
   同等圏まで到達する**。それでも hybrid(in-app)の優位は 1.3〜1.6 倍(wall)/ per-action
   4〜20 倍で残る

## 追補2: 本物の Appium Java Client での実測

Swift 製エミュレーション(appium-java)の妥当性検証として、**本物の Java Client**
(io.appium:java-client 9.5.0 + Selenium 4.27 + JDK 17)で同一4シナリオを実装・計測した。
コード: `Scripts/poc-appium-javaclient/`(pom.xml / PocJavaClientBench.java / run-bench.sh /
aggregate.py)。典型作法: クラス毎に `new IOSDriver` → WebDriverWait(10s) +
findElement(accessibility id / iOSNsPredicate) + click/sendKeys → `quit()`。
warmup 1 + 計測 2 反復・全36クラスラン失敗ゼロ。

- **java-plain**: 上記の素の典型(セッション毎作成・チューニングなし)
- **java-tuned**: できるチューニング全部 = スイート全体で1ドライバ使い回し+usePrebuiltWDA+
  wdaLocalPort 固定+waitForIdleTimeout/animationCoolOffTimeout=0。クラス間は
  terminateApp+activateApp(既存エンジンの launch 意味論と同一)

### 結果(wall 中央値・秒)

| シナリオ | hybrid | xcuitest | appium(snapshot) | **java-tuned** | **java-plain** |
|---|---|---|---|---|---|
| タブナビ | **7.3** | 13.2 | 20.9 | 11.9 | 82.1 |
| カート追加 | **7.3** | 11.2 | 14.0 | 9.4 | 77.8 |
| 検索絞り込み | **4.7** | 8.0 | 9.9 | 6.3 | 74.3 |
| ログイン(3クラス計) | **17.6** | 26.9 | 34.7 | 24.7 | 228.0 |

補足: ftester 系の wall には CLI ハーネス費(ワーカー管理・レポート出力等 ≈1.5〜2.8s/ラン)が
含まれ、Java 側はほぼ裸のステップ+セッション費のみ。ステップ実行部だけの比較は per-action 表参照。

### per-action(中央値)

| 操作 | hybrid | xcuitest | appium(snapshot) | java-plain | java-tuned |
|---|---|---|---|---|---|
| tap | **110〜125ms** | 375〜440ms | 700〜985ms | 509ms | 466ms |
| exist | **4〜15ms** | 30〜55ms | 180〜525ms | 80ms | 80ms |
| type | 820〜1,217ms | 769〜1,326ms | 1,009〜1,656ms | 1,143ms | 1,011ms |
| アプリ再起動(launch相当) | 2.3s | 4.6〜4.7s | 4.3〜4.4s | (セッション作成に内包) | 3.9s |
| セッション作成/クラス | — | — | — | **68〜75s** | (初回のみ) |

### 分析

1. **エミュレーションの答え合わせ**: Swift 再現版 appium-java の「セッション ≈76s・遅さの本体は
   セッションライフサイクル」という結論は本物でも一致(実測 68〜75s/クラス。wall の 85〜95%)。
   一方 per-action はエミュレーション(snapshot 方式ベース)より本物の方が速かった —
   **findElement は対象1要素への XCUITest クエリで済み、画面全体の /source 直列化(可視性計算・
   XML 化・Node 経由の再エンコード)を回避できる**ため。tap で約1.8倍、exist で約4倍の差
2. **チューニングの効果は「セッション使い回し」がほぼ全て**: java-plain → java-tuned の改善
   (82s→12s 等)のうち、waitForIdleTimeout=0 等の設定は誤差レベル(tap 509→466ms)。
   usePrebuiltWDA はマイクロベンチでも効果なし。**Java Client を速くする実践的な答えは
   「スイート全体で1セッション+terminateApp/activateApp でテスト間を区切る」**
3. **チューニングし尽くした Java Client は自作 XCUITest ブリッジと同等圏**(wall では
   ハーネス費の分だけ java-tuned が僅かに速く、ステップ実行部では bridge が僅かに速い)。
   つまり「XCUITest の上に立つ」限り、どの実装でもおよそこの水準が上限
4. **それでも hybrid(in-app)は 1.3〜1.6 倍速い**(wall)。per-interaction では tap 4倍・
   exist 5〜20倍の差があり、ステップ密度が上がるほど開く。in-app 化の本質的優位は
   「XCUITest/AX 境界そのものを消す」ことにあり、Appium 側のどのチューニングでも到達できない
5. **「Java Client は作りが悪い」わけではない**: クライアント自体は薄く、per-action は良好。
   遅さの実体は (a) appium-xcuitest-driver のセッション経済(quit で WDA 死亡→次回コールド
   ブート 40〜75s)、(b) それを踏む「クラス毎セッション」という既定の作法、(c) 本環境では
   beta 起因のバグ税(+25s/セッション)の3層。Android(UiAutomator2)はセッション作成が
   軽いため同じ作法でも痛みは小さい

## 追補3: 自作 XCUITest ブリッジの高速化レバー1(quiescence スキップ)— 否定的結果

「自作ブリッジを限界までチューニングしたら hybrid に並ぶか」の第一歩として、XCUITest の暗黙
quiescence 待ち(アプリのアイドル+アニメーション整定)をスキップする高速入力を実装し実測した。

### 実装(トグル付き・ブランチに残存)

- ランナー側 `Runner/FTesterRunnerUITests/FastInput.swift`: `XCUIApplicationProcess` の private
  メソッド `waitForQuiescenceIncludingAnimationsIdle:isPreEvent:` を swizzle(候補セレクタを全て
  試し、見つからなければ無効化して通常動作 = Xcode 更新耐性)。リクエスト単位のフラグで発火
- 有効化: 実行プロファイル `"iosFastInput": true` または CLI `ftester run --fast-input`
  (FT_FAST_INPUT 環境変数経由で BridgeClient → tap/press/swipe リクエストの `fast` フィールドへ。
  type は対象外 = キーボード出現待ちを quiescence に依存しているため)
- 互換性: 追加フィールドは省略可能のみで双方向互換のため bridgeProtocolVersion は据え置き
  (bump すると稼働中の旧ホスト常駐プロセスが新ランナーを stale 判定して再起動ループに入る)

### 結果(bench-6: 新環境・warmup+2・全ラン green)

| シナリオ | xcuitest | xcuitest-fast | 差 |
|---|---|---|---|
| タブナビ | 13.4s | 13.3s | −0.7% |
| カート追加 | 11.6s | 11.4s | −1.7% |
| 検索絞り込み | 8.6s | 8.6s | 0% |
| ログイン | 28.5s | 27.9s | −2.1% |

swizzle の導入・リクエスト毎の発火はランナーログで確認済み(`FastInput: swizzled ...` /
`FastInput: engaged`)。**発火しているのに速度が変わらない** = 静的なアプリでは quiescence 待ちは
元々ほぼゼロ秒で、タップの実コスト(約360ms)は **XCUITest のイベント合成往復そのもの**。
Appium 側の waitForIdleTimeout=0 が 2〜7% しか効かなかった(追補1)のと同じ帰結が、
ブリッジ直付けの swizzle でも再確認された。

### レバー2: launch の simctl 化(採用効果あり・同トグルに同梱)

`FastLaunchDriver`(fast-input 有効時に xcuitest エンジンへ装着)が launch を
XCUIApplication.launch()(4.6s)から simctl terminate+launch(2.3s)+ activate 接続(≈1.1s)に
置換。launch 中央値 **4,649ms → 3,387ms(−27%)**。bench-7(warmup+2・全ラン green):

| シナリオ | xcuitest | fast(レバー1+2) | 短縮 | hybrid(参考) |
|---|---|---|---|---|
| タブナビ | 13.4s | 11.5s | −14% | 7.9s |
| カート追加 | 11.6s | 9.7s | −16% | 7.7s |
| 検索絞り込み | 8.6s | 6.8s | −21% | 5.2s |
| ログイン(launch×3) | 28.5s | 23.1s | −19% | 18.9s |

### 統一判断への含意(最終)

- レバー2 適用後も hybrid 比 **1.2〜1.5 倍**が残る。残差の本体は per-interaction
  (tap 約380ms vs 約120ms・exist 約40ms vs 約10ms)= XCUITest イベント合成往復と
  プロセス間スナップショットのコストで、quiescence スキップ(レバー1)では消えない
- 残レバーだった「イベント合成の私有 API 直叩き」は docs/performance-tuning.md §6 に
  **既に不採用として記録済み**(idb 方式=AXRuntime+IndigoHID。理由: 整定のイベント源が無く
  ポーリング回帰=負荷原則違反、Xcode beta 毎に壊れるリスク)。同文書は「税の撤廃=アプリ内
  常駐ブリッジ」を設計解として明記しており、**in-app エンジンはまさにこの分析の産物**
- 結論: **「ブリッジを hybrid 同等まで寄せて統一」は不成立**(±10% ゲート不達+私有API路線は
  既却下)。現実解は「hybrid を主・xcuitest を fast-input 付きの汎用フォールバック
  (実機・注入不可アプリ・システムUI)」の現行2層を維持し、fast-input(レバー1+2・既定off)を
  xcuitest 利用時の底上げとして残すこと

### 計測環境の注記(追補3のみ他と異なる)

追補3 実施中に Xcode が beta 3→4 に更新されたため(beta_3 は削除済み)、iOS 27.0 ランタイム
24A5390f を導入し、専用シミュレータを新ランタイムで再作成して計測した(bench-6)。旧環境の
数値(本編・追補1〜2)との比較では hybrid が 7.3→7.9s 等の +3〜8% の系統差があり、
追補3内の比較(xcuitest vs xcuitest-fast)は同一環境内で閉じている。なお切り分け中に
判明した実害2件: (1) sut-ec-mobile の dev サーバ(localhost:8090)停止中はアプリが検索画面で
クラッシュ(Kotlin coroutine 未処理例外)しテストが全滅する、(2) beta_4 の xcodebuild で
ビルドしたランナーは beta_3 ランタイムに対して不安定(要ランタイム整合)。

## PoC 実装の構成(このブランチの差分)

- 新規: `Sources/FTBridgeClient/AppiumDriver.swift`(W3C セッション管理・永続化・W3C Actions。
  `javaClientStyle` で Java Client 再現モード: セッション使い捨て+findElement/element click)、
  `Sources/FTBridgeClient/AppiumSource.swift`(WDA/UiAutomator2 XML → SnapshotResponse 正規化。
  既存ブリッジとフィルタ規則・要素上限をパリティ)
- 変更: RunProfile(`engine` フィールド。"appium" / "appium-java")、ScenarioRunnerMain(appium 分岐)、
  ProfileWorkerFactory(appium 系はブリッジ供給をバイパス)、ScenarioHost(`FT_EVENT_LOG_PATH`
  による NDJSON テー出力=本ベンチの計測口)
- チューニング注入(ベンチ用): 環境変数 `FT_APPIUM_TUNED`(waitForIdle 系 settings)、
  `FT_APPIUM_USE_PREBUILT_WDA` / `FT_APPIUM_WDA_LOCAL_PORT` / `FT_APPIUM_WDA_URL`(caps)
- 既存エンジンの挙動・`ftester api` 契約は不変(`swift test` green)

## Appium 統合で踏んだ実バグ(追補分)

- appium-ios-simulator: セッション DELETE→即 CREATE、または create-over 時に「Simulator is not
  in 'Shutdown' state after 15000ms」で 500(iOS 27 beta の状態報告との相性)。対策: javaClientStyle
  では明示 DELETE をやめ obsolete 自動終了に任せる+該当エラーは 5s 待って1回リトライ
- セッション生存プローブに `/appium/settings` は不可(サーバ内で完結し WDA の死を検知できない)。
  `/window/rect`(デバイス往復)を使う
