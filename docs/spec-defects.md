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
| 24 | `screenLooksLike` は docs 自身が「厳密な合否ゲートに使わない」と書くのに、失敗でシナリオを中断し、アサーションに数えて「検証が無い」警告も黙らせる | 中 | 中 | 要決定 | アサーションの計数から外すのは小。警告化はユーザー決定 | `docs/commands.md:452` / `Sources/FTCore/Flow.swift:96` |

## 2. 実行環境で意味が変わるのに事前に分からない

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|
| 26 | コマンド × エンジン・端末種別の事前検知が無い。dry-run はプロファイルを読まず、`CommandIndex` に要件欄も無いので、下の ❌ はすべてデバイス実行のそのステップで初めて 501 / 422 として出る | 中 | 大 | コード | `CommandIndex` に要件欄を足し、dry-run がプロファイルを読んで照合する | `Sources/fleetest/Fleetest.swift:802` / `Sources/FTCore/CommandIndex.swift` |
| 21 | hybrid / inapp で findImage・existImage・imageIs・分類器・可視性検証の OCR/FM が読む絵は in-app の描画で、キーボード・システムアラート・他プロセスが写らない。**`screenshot()` は XCUITest で撮るようにした**(2026-10-20)が、画像判定の絵は変えていない | 中 | 大 | コード | 画像判定の絵も XCUITest で撮るか、判定の前にシステムアラートが前面にないかを確かめる(撮るたびの往復が性能に響く) | `Sources/FTCore/StepExecutor+FindImage.swift` / `StepExecutor+Assert.swift` |
| 34 | `@TestClass(app:)` は OS 共通の1文字列で、OS で ID が違う複数アプリのプロジェクトを表せない | 低 | 中 | 要決定 | `ios:` / `android:` の引数を足し、解決と docs を揃える | `Sources/FTDSLMacros/TestClassMacro.swift:162` / `Sources/FTCore/ScenarioAppResolution.swift` |

## 3. 文書と実装・文書同士の食い違い

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|

### 監査エージェントの報告から写したもの(行未確認)

| # | 欠陥 | 重要度 | コスト | 区分 | 直し方の要点 | 場所 |
|---|---|---|---|---|---|---|

## 欠陥ではなかったもの(再調査を省く)

- **可視性検証の親スイッチが幾何の段まで切る**(旧 3 番): 意図した契約だった。`fmTextVisibilityCheck` と
  `ocrTextVisibilityCheck` を両方 false にすると、画面外の要素も `exist` が素通りする。docs/commands.md の `requireVisible` は
  「確認が実際に走るのは…が有効な run」と書き、`StepExecutorTests.testOffscreenMatchPassesWhenTheVisibilityGuardIsOff` が
  この形を固定している。幾何の段だけを常に効かせるなら、この契約を変える決定が要る(既定はどちらも true なので、効かないのは両方を切った run だけ)

- **`fold` / `unfold` / `hinge` の非対応の実機の扱いが OS で割れる**(旧 27 番): 意図した設計。iOS 実機は折りたためるかを観測できないので、分からないものを黙って対象外(skipped)にせず失敗にする。docs/commands.md の `fold` に「物理端末は非対応で失敗」と明記がある。Android 実機は `device_state` で折りたためるかを読めるので、折りたためない機は skipped になる
- **`type("…")` の1引数形がセレクタらしい文字列を断る**(旧 33 番): 利用者向けの type のページ(ja/en)に、断る理由と2引数形の逃げ道が既に書いてある

- **iOS の `back()` が結果を確かめない**(旧 23 番): DSL の `back()` は前後の木を読み比べ、変わらなければ注記 `backIneffective` を残す(`FTCore.BackEffect` を MCP の `ft_navigate` と共有)。監査ではドライバの `back()` だけを読んでいた
- **Android 実機だけの run でも公開ポートを LAN に開く**(旧 41 番): 意図した設計。Android 実機のアプリが LAN のアドレスを焼き込んでビルドされていれば `adb reverse` では届かないので、LAN 公開と reverse の両方を用意する。docs の「実機のレーンを含む run では必須」と一致

## 推測のまま残っているもの(実測で確かめる)

- hybrid の WebView 委譲中に `keyboardIsNotShown` が「cannot determine」で落ちる可能性(委譲中は XCUITest の木を返すため)。
  場所: `Sources/FTBridgeClient/WebViewDelegatingDriver.swift:28` / `Sources/FTCore/KeyboardWait.swift:31`
- 40 の実害(経路はコードで確定、デバイスで再現していない)

## 着手の順の目安

高 × 小は 2026-10-20 に片付けた(1・2 は修正、3 は設計どおりと確認、4・7 は docs への明記)。高 × 中も同日に片付けた(5 は修正、6 は治した回の印まで)。コスト小も同日に片付けた(17 は直し方を詰めるとブリッジの版上げが要るので中へ、27・33 は欠陥ではなかった、45 は実測して docs へ明記)。コスト中も同日に片付けた(17・18・19・20・25・45 は修正 = 20 は別アプリの launch を断る形、21 は `screenshot()` だけ、23・41 は欠陥ではなかった)。要決定の 22・24・34 は残す。次は中 × 小の 8〜17。要決定の 6・7・22・24・34 は、直す前に方針を決める。
