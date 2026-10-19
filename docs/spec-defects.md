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
| 8 | 中断(SIGINT/SIGTERM)で始まらなかったシナリオが JUnit では `<skipped>`。exit code と run.json は failed に数える。ci.md は「対象外の未実行だけが skipped」 | 中 | 小 | コード | `isSkipped` の除外に `.interrupted` を足す | `Sources/FTCore/JUnitReportWriter.swift:59` / `docs/ci.md:40` |
| 9 | MCP の操作ツールに `waitSeconds` だけを渡すと黙って無視される(`waitFor` / `waitForChange` が無いと読まれず、注記も無い)。DSL の `waitSeconds:` とは意味(対象を探す待ち・既定約 0.7 秒)も違うのに、サーバ説明は同一性を強調する | 中 | 小 | コード | 注記関数に `waitSeconds` 単独も加える。説明文に DSL との差を1文 | `Sources/fleetest-mcp/MCPServer+Snapshot.swift:597` / `MCPServer+ToolDefs.swift:168` |
| 22 | `readMemo` の未登録キーは `""` で続行する。シナリオが別デバイスへ散った run では書いた側と読む側が別の台になり、空文字のまま入力して誤った緑になる(Shirates は多デバイス分配を持たない) | 中 | 中 | 要決定 | 「同じ run の別デバイスでは書かれている」と親が知るときだけ失敗にする。Shirates 準拠からの差になる | `Sources/FTDSL/CommandsMemo.swift:40` |
| 23 | iOS の `back()` は結果を確かめない。戻るボタンの無い画面ではエッジスワイプに落ち、成立しなければ下の要素に触れて緑のまま進む | 中 | 中 | コード | 前後の木の署名を比べ、変化が無ければ注記か失敗 | `Sources/FTBridgeClient/BridgeClient.swift:951` |
| 24 | `screenLooksLike` は docs 自身が「厳密な合否ゲートに使わない」と書くのに、失敗でシナリオを中断し、アサーションに数えて「検証が無い」警告も黙らせる | 中 | 中 | 要決定 | アサーションの計数から外すのは小。警告化はユーザー決定 | `docs/commands.md:452` / `Sources/FTCore/Flow.swift:96` |

## 2. 実行環境で意味が変わるのに事前に分からない

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 26 | コマンド × エンジン・端末種別の事前検知が無い。dry-run はプロファイルを読まず、`CommandIndex` に要件欄も無いので、下の ❌ はすべてデバイス実行のそのステップで初めて 501 / 422 として出る | 中 | 大 | コード | `CommandIndex` に要件欄を足し、dry-run がプロファイルを読んで照合する | `Sources/fleetest/Fleetest.swift:802` / `Sources/FTCore/CommandIndex.swift` |
| 13 | `engine: inapp` 単独で常に失敗する操作の一覧が docs に無い(`home` / `back` / `appSwitcher` / `tapAppIcon` / `fold` / drag 族 / `tap(holdSeconds:)` / UIKit 系の `doubleTap`・`pinch*` / Flutter の `clearInput`・`pressEnter`)。commands.md の「XCUITest へ自動フォールバック」は hybrid 前提 | 中 | 小 | docs | commands.md に1節。「自動フォールバック」の各所に hybrid 前提を添える | `Sources/FTBridgeClient/InAppDriver.swift:243` / `docs/commands.md:277`・`:304` |
| 11 | xcuitest 単独でも SpringBoard の照会と `iosAlertHandler` は効く(ランナーが `SystemUIDriver` を注入)のに、docs は「xcuitest 単独は掴めない」「hybrid のときだけ効く」。commands.md 内でも 1078 行と 1208 行が矛盾。実機は常に xcuitest なので、実機の利用者が権限アラートを扱えないと読む | 中 | 小 | docs | commands.md の2箇所と `ios_alert_handler` の ja/en を直す | `Sources/FTScenarioRunner/ScenarioRunnerMain.swift:463` / `docs/commands.md:1078`・`:1151`・`:1208` / `docs/user-docs/reference/commands/ios_alert_handler_ja.md:33` |
| 12 | MCP の iOS は常に XCUITest なのに、`ft_run_scenario` と `ft_start_run`(プロファイルのエンジン)の差が応答にも docs にも出ない。`ft_double_tap` / `ft_pinch` の説明は「iOS では `profile:` を渡せ」と存在しない切替を案内する | 中 | 小 | コード | `ft_run_scenario` の iOS 応答に「XCUITest で走らせた」注記を必須にする。説明文2つを実行時の注記と同じ文に差し替える | `Sources/fleetest-mcp/MCPServer+ToolDefs.swift:414`・`:431` / `docs/user-docs/reference/tools/mcp_server_ja.md:76` |
| 17 | `tap(x:y:)` のキーボード上・画面外の点は in-app が 422 を返し、既定の hybrid でもフォールバックしない(xcuitest 単独なら押せる)。d2f2bcc0 の「キーボードの下の対象へ閉じてから届かせる」はセレクタ指定だけで、座標タップは対象外 | 中 | 小 | コード | 座標系の 422 を本文の接頭辞で見分けて XCUITest へ回す。docs も直す | `Sources/FTCore/StepExecutor+DirectActions.swift:361` / `InAppBridge/Sources/InAppBridge.swift:505`・`:513` |
| 18 | dry-run の対象 OS の決め方が `fleetest run`(`--platform` だけ)と `api run`(プロファイルのデバイス構成)で違う。同じ `--profile android-run --dry-run` が CLI では iOS を検証して緑になる | 中 | 中 | コード | CLI もプロファイルから既定 OS を決める。`RunCommandFlagParityTests` を更新 | `Sources/fleetest/Fleetest.swift:802` / `Sources/fleetest/ApiRunCommand.swift:1285` / `docs/user-docs/reference/running/dry_run_ja.md:38`。MCP の `ft_dry_run` も宣言の無いシナリオを `args["platform"] ?? "ios"` で決める(`serial` だけの呼び出しが iOS になる。`MCPServer+ScenarioTools.swift:110`) |
| 19 | `appIs(他のアプリ)` は hybrid / inapp で常に赤。in-app の `/appstate` は自アプリ以外を常に false と答える | 中 | 中 | コード | hybrid では fallbackDriver に前面を聞く。inapp 単独は docs に明記 | `InAppBridge/Sources/InAppBridge.swift:220` / `Sources/FTDSL/CommandsAppControl.swift:182` |
| 20 | hybrid / inapp でシナリオの途中に別アプリを `launchApp` すると、in-app が同じ `FT_PORT` で dylib を注入して起動する(推測: 実害は未再現)。MCP 側の `HybridFallbackDriver` にある門がシナリオ経路に無い | 中 | 中 | コード | シナリオ経路にも同じ門を置き、別 bundle は XCUITest で起動 | `Sources/FTBridgeClient/WebViewDelegatingDriver.swift:352` / `Sources/FTBridgeClient/InAppLauncher.swift:93` |
| 21 | hybrid / inapp の `screenshot()` と、findImage・existImage・imageIs・分類器・可視性検証の OCR/FM が読む絵は in-app の描画で、キーボード・システムアラート・他プロセスが写らない | 中 | 中/大 | コード | `screenshot()` だけ XCUITest で撮るのは中。画像判定全体は性能に響くので大 | `Sources/FTDSL/FTRuntime.swift:1465` / `Sources/FTBridgeClient/InAppDriver.swift:254` |
| 25 | udid が引けない run(`port` 直指定でブリッジが udid を申告しない)は、データコンテナの書き込みと `SimctlPolicy` のデバイス照合が全 Simulator に開く。docs は「他の Simulator のものは書けません」と無条件 | 中 | 中 | コード | udid 不明なら simctl の破壊系を断る、または `port` 直指定に udid を必須にする | `Sources/FTCore/ScenarioSandbox.swift:443` / `Sources/FTCore/SandboxBroker.swift:76` / `docs/user-docs/reference/running/sandbox_access_ja.md:27` |
| 27 | `fold` / `unfold` / `hinge` の「非対応の実機」の扱いが OS で割れる。iOS 実機は常に失敗、Android 実機の非対応機は skipped(exit code が変わる)。docs は両方を併記 | 低 | 小 | コード | iOS 実機も notApplicable(skipped)に揃える | `Sources/FTDSL/CommandsFold.swift:63`・`:73` / `docs/commands.md:791` |
| 28 | `type` の `\n` は「エンジンで結果が変わらない」と書くが、inapp 単独は in-app の `insertText` 経路になり、末尾だけ Enter・文中は本文に挿入される | 低 | 小 | docs | commands.md:224 に但し書き、または inapp 単独で改行入りを断る | `Sources/FTCore/StepExecutor+Actions.swift:826` / `InAppBridge/Sources/InAppBridge.swift:966` / `docs/commands.md:224` |
| 29 | shirates-parity の「OS で挙動が割れるもの」表の網羅漏れ。`countIs`(iOS は画面外の行も木に残る)・`appSwitcher`・`clearAppData`・`keyboardIsNotShown`・`waitForSettle`・`doubleTap`・`openURL` が無い | 低 | 小 | docs | 表に行を足す | `docs/shirates-parity.md:282` |
| 34 | `@TestClass(app:)` は OS 共通の1文字列で、OS で ID が違う複数アプリのプロジェクトを表せない | 低 | 中 | 要決定 | `ios:` / `android:` の引数を足し、解決と docs を揃える | `Sources/FTDSLMacros/TestClassMacro.swift:162` / `Sources/FTCore/ScenarioAppResolution.swift` |

## 3. 文書と実装・文書同士の食い違い

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 14 | ランナー機の `sandbox.disabled` が黙って効く(無効時の告知が無い)。同じページで「常に有効」と「その Mac の設定が使われる」が矛盾 | 中 | 小 | コード | 無効時に警告を1行出す。remote_runners の安全節に書く | `Sources/FTCore/ScenarioSandbox.swift:190` / `Sources/FTCore/ScenarioHost.swift:677` / `docs/user-docs/security/sandbox_ja.md:428`・`:448` |
| 15 | about の「テストの実行時はアプリや画面の情報が Mac の外に出ません」はリモートランナー構成で成り立たない。quality は正しく「フリートの外」 | 中 | 小 | docs | quality と同じ表現に揃える(ja/en) | `docs/user-docs/overview/about_ja.md:57`・`about.md:59` |
| 16 | compose.yaml の `build:` は `--network none` 無しでビルドされ外へ出られる。services docs の「外部へ出られません」は実行時だけ | 中 | 小 | docs | services の規則に1行。閉域網は事前ビルドして `image:` で指すと案内 | `Sources/FTServices/RuntimeCommands.swift:28` / `docs/user-docs/reference/writing/services_ja.md:75` |
| 10 | `scenarioTimeout` の既定が、VSCode のスキーマと `RunProfile` の doc コメントは 90、実装と利用者 docs は 600 | 中 | 小 | docs | スキーマと doc コメントを 600 に(スキーマには `default` も) | `vscode-fleetest/schemas/run-profile.schema.json:125` / `Sources/FTCore/RunProfile.swift:390` / `Sources/FTCore/ScenarioHost.swift:113` |
| 30 | `skipKind: notApplicable` の run.json `total` への数え方が2形(子の宣言は total に含む・プロファイルの OS 対象外の合成は total の外)。results-json.md の恒等式が片方で崩れる。全シナリオが対象外なら1本も走らず exit 0 になることも利用者 docs に無い | 低 | 小 | docs | results-json.md に明記するか集計を統一。parallel_execution に「全部対象外なら緑」を書く | `Sources/fleetest/ProfileRunner.swift:343` / `docs/results-json.md:374` |
| 31 | services の例「アプリとシナリオは `api` に `127.0.0.1:8080` で届きます」は Android Emulator のアプリに当てはまらない(`10.0.2.2`) | 低 | 小 | docs | Emulator のアプリは `10.0.2.2:8080` と補う(ja/en) | `docs/user-docs/reference/writing/services_ja.md:59` |
| 32 | `ft_batch` は DSL で正当な `holdSeconds: 0` を拒否する。commands.md が「ft_batch も settle を受ける」と書く対象のうち `hold` / `flick*` / `gesture` / `back` は ft_batch に無い | 低 | 小 | コード | `holdSeconds` の下限 0 を許す(0 = 通常タップ)。commands.md の但し書きを「ft_batch が持つコマンドでは」に | `Sources/FTCore/ArgumentBounds.swift:58` / `docs/commands.md:59` |
| 33 | `type("…")` の1引数形は、`#` + 英数字の1語や `\|\|` / `>>` を含む文字列を、ハッシュタグや本文でも実行前に拒否する | 低 | 小 | docs | 2引数形の逃げ道を docs に明記。判定を絞るなら中 | `Sources/FTCore/FTSelector.swift:904` |
| 46 | `hideKeyboard` が「🟢 fleetest 独自」の印。Shirates にも同名のコマンドがあるので凡例の定義と合わない | 低 | 小 | docs | 🟡 にし、iOS の手段の違いを差として書く | `docs/shirates-parity.md:82` |

### 監査エージェントの報告から写したもの(行未確認)

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 35 | 供給段で落ちた `--profile` run の `fmSettings` に、プロファイルの実効値でなくプロファイル無しの近似(`heal: false`)が書かれる。results-json.md は「実際に効いていた値」と定義 | 低 | 小 | コード | 欄を省略できる型にするか、results-json.md に注記 | `Sources/fleetest/Fleetest.swift:898` / `docs/results-json.md:271` |
| 36 | design.md §14.3 が「インデックス/キャッシュは未導入」のまま。results-json.md は出力キャッシュと `RunRecordPack` を仕様として持つ | 低 | 小 | docs | results-json.md への参照に差し替え | `docs/design.md:5417` |
| 37 | `ft_services` の `down` / `status` が `physical` / `androidSerials` を黙って捨てる | 低 | 小 | コード | `ft_results` と同じく読まれない引数を断る | `Sources/fleetest-mcp/MCPServer+Services.swift:26` |
| 38 | MCP のデバイス記憶の docs が実装より狭く・強い。`profile:` も明示に数えること、断るのは候補が一意でないときだけであることが書かれていない | 低 | 小 | docs | instructions と mcp_server_ja.md に書く | `docs/user-docs/reference/tools/mcp_server_ja.md:49` / `MCPServer+ToolDefs.swift:135` |
| 39 | MCP の `waitFor` は木が 3 秒動かないと切り上げるが、instructions は「外れた待ちは waitSeconds まで走る」と言う | 低 | 小 | docs | instructions に1文 | `Sources/fleetest-mcp/MCPServer+Driver.swift:1718` / `MCPServer+ToolDefs.swift:168` |
| 40 | MCP で払った `ft_snapshot waitFor` は下書きに写らず、draft の `tap("#id")` は DSL 既定の約 0.7 秒の再試行になる(推測) | 低 | 小 | docs | agent_guide に1行、または直前に待った要素への tap に `waitSeconds:` を出す | `Sources/fleetest-mcp/MCPServer+Draft.swift:175` |
| 41 | Android 実機だけの run でも公開ポートを 0.0.0.0 に束縛し `publishForPhysicalDevices` を必須にする(`adb reverse` で足りる) | 低 | 中 | コード | LAN 公開の条件を「iOS 実機のレーンがあるとき」に絞る | `Sources/fleetest/ServicesSession.swift:136` / `Sources/fleetest/ServicesFacts.swift:236` |
| 42 | network_security の「プロキシはループバックだけで待ち受け」が、同じページの Apple Container の表(ゲートウェイ IP でも待ち受け)と矛盾。LAN からの到達は未実測 | 低 | 小 | docs | 本文を「ループバックとコンテナ網のゲートウェイ IP」に直す。LAN 到達を1回実測 | `docs/user-docs/security/network_security_ja.md:21`・`:91` |
| 43 | `FT_` で始まる親の環境変数は無条件でシナリオへ渡る(スクリプトの枠は前方一致をやめている) | 低 | 小 | docs | 「`FT_` で始まる名前を秘密に使わない」と明記 | `Sources/FTCore/ScenarioSandbox.swift:265` / `docs/user-docs/reference/running/sandbox_access_ja.md:54` |
| 44 | sandbox の要約表「レポートの出力先と一時フォルダ以外に書く」を止める、は実際より強い(`.fleetest/` の台帳・キャッシュも書ける)。limitations の「adb と Emulator のポートだけ閉じる」は実際より弱い(Docker の 2375/2376 も閉じる) | 低 | 小 | docs | 書ける場所に状態の記録を足す。limitations に 2375/2376 を足す | `docs/user-docs/security/sandbox_ja.md:16` / `limitations_ja.md:12` / `Sources/FTCore/ScenarioSandbox.swift:417`・`:649` |
| 45 | シナリオは `localhost:*` で待ち受けられ、Seatbelt の `localhost` が自機の全アドレスを含むなら LAN からの着信で持ち出せる。adb サーバの自動起動で 5037 を先取りしうる | 要実測 | 小 | 要実測 | bind を `127.0.0.1` に限定できるか実測し、できなければ limitations に書く | `Sources/FTCore/ScenarioSandbox.swift:641` / `docs/sandbox-seatbelt.md:71`・`:412` |

## 欠陥ではなかったもの(再調査を省く)

- **可視性検証の親スイッチが幾何の段まで切る**(旧 3 番): 意図した契約だった。`fmTextVisibilityCheck` と
  `ocrTextVisibilityCheck` を両方 false にすると、画面外の要素も `exist` が素通りする。docs/commands.md の `requireVisible` は
  「確認が実際に走るのは…が有効な run」と書き、`StepExecutorTests.testOffscreenMatchPassesWhenTheVisibilityGuardIsOff` が
  この形を固定している。幾何の段だけを常に効かせるなら、この契約を変える決定が要る(既定はどちらも true なので、効かないのは両方を切った run だけ)

## 推測のまま残っているもの(実測で確かめる)

- hybrid の WebView 委譲中に `keyboardIsNotShown` が「cannot determine」で落ちる可能性(委譲中は XCUITest の木を返すため)。
  場所: `Sources/FTBridgeClient/WebViewDelegatingDriver.swift:28` / `Sources/FTCore/KeyboardWait.swift:31`
- 20・40・45 の実害(経路はコードで確定、デバイスで再現していない)

## 着手の順の目安

高 × 小は 2026-10-20 に片付けた(1・2 は修正、3 は設計どおりと確認、4・7 は docs への明記)。高 × 中も同日に片付けた(5 は修正、6 は治した回の印まで)。次は中 × 小の 8〜17。要決定の 6・7・22・24・34 は、直す前に方針を決める。
