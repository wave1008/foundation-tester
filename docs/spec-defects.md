# 仕様上の欠陥(文書と実装の食い違い・未定義・沈黙する縮退)

2026-10-19〜20 の仕様監査で見つけた項目の一覧。docs/open-issues.md(デバイスで出た不具合の候補)とは**別に管理する**。
こちらは「仕様として誤っている・書かれていない・文書同士が食い違う」もので、デバイスでの再現を前提にしない。

**判定は 2026-10-20 の HEAD(f2c74e42)のソースと docs を読んだ結果で、デバイスでの再現はしていない**。
行番号は HEAD 時点のもの(ずれていたら関数名で引く)。「(推測)」は経路をコードから推したもので、実測していない。
「(行未確認)」は監査エージェントの報告をそのまま写したもので、行番号を本人が当てていない。

直したら項目を消す(経緯はコミットに残す)。据え置くと決めたものは理由を付けて「据え置き」節へ移す。

## 判定の基準

| 欄 | 値 | 意味 |
|---|---|---|
| 重要度 | 高 | 誤った緑・データやデバイスへの実害・セキュリティの約束違反 |
| | 中 | デバイス実行の途中で初めて赤になる / CI・運用で誤読する |
| | 低 | 文言・網羅の漏れ |
| コスト | 小 | docs だけ、または 1 箇所の条件・定数 |
| | 中 | 1〜2 ファイルのロジック変更とテスト |
| | 大 | 設計判断・新しい口・複数経路にまたがる・ユーザー決定の見直し |
| 区分 | docs | 文書を直せば済む |
| | コード | 実装を直す |
| | 要決定 | 直す向きにユーザーの決定が要る(Shirates 準拠・既定値の変更など) |
| | 要実測 | 欠陥かどうかをデバイスか実機で確かめる必要がある |

「小/大」は「docs の明記だけなら小・根本対処なら大」。

## 1. 緑に化ける・沈黙する

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 4 | Wi-Fi で繋いだ iOS 実機を含む run は Seatbelt に `*:<port>` を開け、そのポート番号なら任意のホストへ出られる(プロキシ・allowedDomains を通らない)。**docs への明記は済み**(sandbox_access・limitations・network_security・quality の ja/en) | 高 | 大 | コード | iproxy 必須化か、ポート限定の中継で宛先を実機に絞る | `Sources/FTCore/ScenarioSandbox.swift:644` / `docs/user-docs/reference/running/sandbox_access_ja.md:65`・`overview/quality_ja.md:52`・`security/network_security_ja.md:81` |
| 6 | 自己修復(指紋照合)は profile 実行で既定 ON。指紋は型とラベルだけで画面の文脈を持たないので、遷移に失敗して前の画面に同名ボタンが1つあれば「治って」緑になる。**治した回の印は出すようになった**(JUnit の `<system-out>` と run 末尾の ⚠️ の行。`HealedScenarios`)が、合否は変えない | 高 | 大 | 要決定 | 既定 OFF にするか、CI では治した回を赤にするか(ユーザー決定) | `Sources/FTCore/LocatorFingerprint.swift:15` / `Sources/FTCore/HealedScenarios.swift` |
| 7 | 振り直し(requeue)はシナリオを最初から再実行し、凍結確定時は直前の**成功した**シナリオも対象。購入・送信を済ませたシナリオが2回走り得る。止める口が無い。**docs への明記は済み**(docs/ci.md・user-docs の ci の ja/en) | 高 | 大 | 要決定 | `@Test` かプロファイルに「振り直し不可」の宣言口を足し、run / api run の両方へ通す | `Sources/FTCore/RunOrchestrator.swift:898`(`requeuesWithoutRetiring`)/ `docs/design.md:2768` / `docs/ci.md:158` |
| 22 | `readMemo` の未登録キーは `""` で続行する。シナリオが別デバイスへ散った run では書いた側と読む側が別の台になり、空文字のまま入力して誤った緑になる(Shirates は多デバイス分配を持たない) | 中 | 中 | 要決定 | 「同じ run の別デバイスでは書かれている」と親が知るときだけ失敗にする。Shirates 準拠からの差になる | `Sources/FTDSL/CommandsMemo.swift:40` |
| 23 | iOS の `back()` は結果を確かめない。戻るボタンの無い画面ではエッジスワイプに落ち、成立しなければ下の要素に触れて緑のまま進む | 中 | 中 | コード | 前後の木の署名を比べ、変化が無ければ注記か失敗 | `Sources/FTBridgeClient/BridgeClient.swift:951` |
| 24 | `screenLooksLike` は docs 自身が「厳密な合否ゲートに使わない」と書くのに、失敗でシナリオを中断し、アサーションに数えて「検証が無い」警告も黙らせる | 中 | 中 | 要決定 | アサーションの計数から外すのは小。警告化はユーザー決定 | `docs/commands.md:452` / `Sources/FTCore/Flow.swift:96` |

## 2. 実行環境で意味が変わるのに事前に分からない

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 26 | コマンド × エンジン・端末種別の事前検知が無い。dry-run はプロファイルを読まず、`CommandIndex` に要件欄も無いので、下の ❌ はすべてデバイス実行のそのステップで初めて 501 / 422 として出る | 中 | 大 | コード | `CommandIndex` に要件欄を足し、dry-run がプロファイルを読んで照合する | `Sources/fleetest/Fleetest.swift:802` / `Sources/FTCore/CommandIndex.swift` |
| 17 | `tap(x:y:)` のソフトキーボードの上の点は in-app が 422 を返し、既定の hybrid でもフォールバックしない(xcuitest 単独なら押せる)。d2f2bcc0 の「キーボードの下の対象へ閉じてから届かせる」はセレクタ指定だけで、座標タップは対象外 | 中 | 中 | コード | in-app がこの点を 501(エンジンにできない)で返すようにする。422 を本文の文言で見分けるのは規律に反するので、ブリッジの版上げとデバイスでの E2E が要る | `Sources/FTCore/StepExecutor+DirectActions.swift:361` / `InAppBridge/Sources/InAppBridge.swift:513` |
| 18 | dry-run の対象 OS の決め方が `fleetest run`(`--platform` だけ)と `api run`(プロファイルのデバイス構成)で違う。同じ `--profile android-run --dry-run` が CLI では iOS を検証して緑になる | 中 | 中 | コード | CLI もプロファイルから既定 OS を決める。`RunCommandFlagParityTests` を更新 | `Sources/fleetest/Fleetest.swift:802` / `Sources/fleetest/ApiRunCommand.swift:1285` / `docs/user-docs/reference/running/dry_run_ja.md:38`。MCP の `ft_dry_run` も宣言の無いシナリオを `args["platform"] ?? "ios"` で決める(`serial` だけの呼び出しが iOS になる。`MCPServer+ScenarioTools.swift:110`) |
| 19 | `appIs(他のアプリ)` は hybrid / inapp で常に赤。in-app の `/appstate` は自アプリ以外を常に false と答える | 中 | 中 | コード | hybrid では fallbackDriver に前面を聞く。inapp 単独は docs に明記 | `InAppBridge/Sources/InAppBridge.swift:220` / `Sources/FTDSL/CommandsAppControl.swift:182` |
| 20 | hybrid / inapp でシナリオの途中に別アプリを `launchApp` すると、in-app が同じ `FT_PORT` で dylib を注入して起動する(推測: 実害は未再現)。MCP 側の `HybridFallbackDriver` にある門がシナリオ経路に無い | 中 | 中 | コード | シナリオ経路にも同じ門を置き、別 bundle は XCUITest で起動 | `Sources/FTBridgeClient/WebViewDelegatingDriver.swift:352` / `Sources/FTBridgeClient/InAppLauncher.swift:93` |
| 21 | hybrid / inapp の `screenshot()` と、findImage・existImage・imageIs・分類器・可視性検証の OCR/FM が読む絵は in-app の描画で、キーボード・システムアラート・他プロセスが写らない | 中 | 中/大 | コード | `screenshot()` だけ XCUITest で撮るのは中。画像判定全体は性能に響くので大 | `Sources/FTDSL/FTRuntime.swift:1465` / `Sources/FTBridgeClient/InAppDriver.swift:254` |
| 25 | udid が引けない run(`port` 直指定でブリッジが udid を申告しない)は、データコンテナの書き込みと `SimctlPolicy` のデバイス照合が全 Simulator に開く。docs は「他の Simulator のものは書けません」と無条件 | 中 | 中 | コード | udid 不明なら simctl の破壊系を断る、または `port` 直指定に udid を必須にする | `Sources/FTCore/ScenarioSandbox.swift:443` / `Sources/FTCore/SandboxBroker.swift:76` / `docs/user-docs/reference/running/sandbox_access_ja.md:27` |
| 34 | `@TestClass(app:)` は OS 共通の1文字列で、OS で ID が違う複数アプリのプロジェクトを表せない | 低 | 中 | 要決定 | `ios:` / `android:` の引数を足し、解決と docs を揃える | `Sources/FTDSLMacros/TestClassMacro.swift:162` / `Sources/FTCore/ScenarioAppResolution.swift` |

## 3. 文書と実装・文書同士の食い違い

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|

### 監査エージェントの報告から写したもの(行未確認)

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 41 | Android 実機だけの run でも公開ポートを 0.0.0.0 に束縛し `publishForPhysicalDevices` を必須にする(`adb reverse` で足りる) | 低 | 中 | コード | LAN 公開の条件を「iOS 実機のレーンがあるとき」に絞る | `Sources/fleetest/ServicesSession.swift:136` / `Sources/fleetest/ServicesFacts.swift:236` |
| 45 | シナリオは `localhost:*` で待ち受けられ、Seatbelt の `localhost` は自機の全アドレスを含むので、0.0.0.0 で待ち受けて LAN 側から繋いだ接続を受け付けられる(**2026-10-20 に実測**: 枠と同じ規則で 0.0.0.0 に bind でき、この Mac の LAN の IP から繋いだ接続に応答できた。別の機械からは未確認)。**limitations(ja/en)への明記は済み** | 高 | 中 | コード | どの用途が待ち受けを要るかを洗い出し、要らなければ `network-bind` / `network-inbound` を閉じる(Seatbelt はアドレスを `localhost` か `*` でしか書けず、ループバックだけには絞れない) | `Sources/FTCore/ScenarioSandbox.swift` の `network-bind` |

## 欠陥ではなかったもの(再調査を省く)

- **可視性検証の親スイッチが幾何の段まで切る**(旧 3 番): 意図した契約だった。`fmTextVisibilityCheck` と
  `ocrTextVisibilityCheck` を両方 false にすると、画面外の要素も `exist` が素通りする。docs/commands.md の `requireVisible` は
  「確認が実際に走るのは…が有効な run」と書き、`StepExecutorTests.testOffscreenMatchPassesWhenTheVisibilityGuardIsOff` が
  この形を固定している。幾何の段だけを常に効かせるなら、この契約を変える決定が要る(既定はどちらも true なので、効かないのは両方を切った run だけ)

- **`fold` / `unfold` / `hinge` の非対応の実機の扱いが OS で割れる**(旧 27 番): 意図した設計。iOS 実機は折りたためるかを観測できないので、分からないものを黙って対象外(skipped)にせず失敗にする。docs/commands.md の `fold` に「物理端末は非対応で失敗」と明記がある。Android 実機は `device_state` で折りたためるかを読めるので、折りたためない機は skipped になる
- **`type("…")` の1引数形がセレクタらしい文字列を断る**(旧 33 番): 利用者向けの type のページ(ja/en)に、断る理由と2引数形の逃げ道が既に書いてある

## 推測のまま残っているもの(実測で確かめる)

- hybrid の WebView 委譲中に `keyboardIsNotShown` が「cannot determine」で落ちる可能性(委譲中は XCUITest の木を返すため)。
  場所: `Sources/FTBridgeClient/WebViewDelegatingDriver.swift:28` / `Sources/FTCore/KeyboardWait.swift:31`
- 20・40・45 の実害(経路はコードで確定、デバイスで再現していない)

## 着手の順の目安

高 × 小は 2026-10-20 に片付けた(1・2 は修正、3 は設計どおりと確認、4・7 は docs への明記)。高 × 中も同日に片付けた(5 は修正、6 は治した回の印まで)。コスト小も同日に片付けた(17 は直し方を詰めるとブリッジの版上げが要るので中へ、27・33 は欠陥ではなかった、45 は実測して docs へ明記)。次は中 × 小の 8〜17。要決定の 6・7・22・24・34 は、直す前に方針を決める。
