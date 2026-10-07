# 残件(未解決の不具合の候補)

バグ出し(2026-09-06・09-08・09-11)で見つかり、まだ直していない項目の一覧。台帳は削除したので、
未解決の項目だけをここに残す。**判定は 2026-10-07 の HEAD(c87b8c8f)のソースを読んだ結果で、デバイスでの再現はしていない**。
「(推測)」は、症状の経路か指摘の対象をコードから推して特定したもの。

直したら項目を消す(経緯はコミットに残す)。新しい残件は同じ形(症状・場所・手がかり)で足す。

## iOS ブリッジ・in-app

- **型の語彙が in-app と XCUITest で割れている**(09-06)
  - 症状: 同じ型セレクタがエンジンで当たったり外れたりする。SearchField は in-app が "TextField"・XCUITest が "SearchField"、
    PickerWheel は in-app が返さない、ScrollView は in-app が "Other" に scrollable の印を付けるだけ
  - 場所: `InAppBridge/Sources/InAppSnapshot.swift:388`(UITextField の判定が :403 の searchField より先)・:367・:446、
    `Runner/FleetestRunnerUITests/BridgeRouter+Snapshot.swift:260`・263・274
  - 手がかり: 片側に寄せるか契約(`E2EAppCMP/docs/ui-contract.md`)に足し、docs/framework-differences.md に1行。in-app の版上げが要る
- **in-app の合成タッチ(synthFallback)が成否を返せない**(09-06)
  - 症状: activate が効かなかったときの FTSynthTap は成否を返さず、負荷下で RN のタップが黙って空振りし得る(9/6 に 153 回中 3 回)
  - 場所: `InAppBridge/Sources/InAppBridge.swift:585-597`(「throw は追加しない」と明記)
  - 手がかり: 次に出たら1周目からプローブを入れる。成否の検知に `InAppRenderCatchUp` の前後比較を流用できるか
- **XCUITest の handler で、要素を確かめてから同じ要素へ撃つまでの窓(TOCTOU)**(09-06・推測)
  - 症状: `focused.exists` から `focused.typeText` 等までの間に焦点の移動や背面化が起きると、要素スコープの XCUI 呼び出しが失敗し
    ランナーを落とし得る
  - 場所: `Runner/FleetestRunnerUITests/BridgeRouter.swift:673-679`(handlePressEnter)、`BridgeRouter+TextInput.swift:350-370`(clear)
  - 手がかり: `/type` と同じく `app.typeText` に寄せられるか
- **XCUITest で secure 欄・横向きのとき `focused` が申告されない**(09-11)
  - 症状: 焦点のある要素の frame と木の frame の完全一致でしか印を付けないので、印が無い → `InputFocusRescue.focusIsElsewhere` が
    true になり、誤った警告と不要な焦点救済が走る(一致しない原因は推測)
  - 場所: `Runner/FleetestRunnerUITests/BridgeRouter.swift:271-281`(withFocusedFlag)、`Sources/FTCore/InputFocusRescue.swift:35`
  - 手がかり: 誤差の許容と向きの換算を入れる
- **アプリが落ちても「別のアプリが前面」と報告される**(09-11)
  - 症状: `requireForegroundApp()` が落ちたアプリ(`.notRunning`)も「another app is in the foreground」の 422 にする。
    クラッシュを言う 503(`requireLiveApp`)は操作系だけが使う
  - 場所: `Runner/FleetestRunnerUITests/BridgeRouter.swift:1332-1340`・:239・:1256
  - 手がかり: snapshot の経路でも `.notRunning` を 503 で名指しする(ブリッジの版上げ)

## StepExecutor・DSL

- **`gestureFallbackLatched` が path 付き swipe の 501 でも立つ**(09-06)
  - 症状: `scrollFrame` 付きの swipe は in-app で必ず 501 になるので1回でラッチが立ち、以後は path 無しの swipe まで XCUITest の
    実スワイプになる(バウンス由来のフレーク)。長押しの 501 も同じラッチを立てる(`StepExecutor+Actions.swift:672`)
  - 場所: `Sources/FTCore/StepExecutor+Settle.swift:533`・:553
  - 手がかり: `path != nil` の 501 ではラッチを立てず、press とも分ける(`dragFallbackLatched` を分けたのと同じ理由)
  - **Flutter の in-app の払いの不具合と組で直す**(2026-10-07 に試した): ラッチを path の有無と press で分けると、
    E2E-Flutter の iOS in-app で S0091(05_スクロール)の scene 5 が決定的に赤になる。`scrollFrame` 無しの横の払いを
    in-app で撃つと、画面中央の縦リストではなくカルーセルが動く(`#tag_01` が消える)。今は共有ラッチのせいで scene 5 の
    払いが XCUITest で撃たれていて(緑のレポートに `fell back to XCUITest`)、in-app の確認用のはずの scene 5 が
    XCUITest を確かめている。先に in-app(Flutter の UIAccessibility の scroll の対象選び)を直してから、ラッチを分ける

- **fallback ドライバで解決した要素を primary の木で取り直す(ref の名前空間が混ざる)**(09-06)
  - 症状: `actingDriver = fb` に切り替えた後も、容器をまたぐ寄せと `waitUntilEnabled` が primary の木を読み、primary の ref を
    fb へ撃つ
  - 場所: `Sources/FTCore/StepExecutor+Actions.swift:466`(切替)・:550・:568・:1891、`StepExecutor.swift:793`
  - 手がかり: `actingDriver !== driver` のときは `actingDriver.snapshot()` で取り直すか、その2段を飛ばす
- **`select` が occlusion-guard の FM 待ちを抱え、締め切りから差し引かれない**(09-06・一部残る)
  - 症状: `select` は今も `occlusionFlip` を通って FM を待つことがあり、FM のゲート待ちは scenarioTimeout から差し引かれない。
    OCR の段で FM の呼び出しは 97% 減り(46b54f84)、9/7 以降は打ち切りの観測が無い
  - 場所: `Sources/FTCore/StepExecutor+Actions.swift:577-591`、`StepExecutor+Assert.swift:101〜`(`DeadlineExclusion` は OCR の
    コンパイル等にしか掛かっていない)
  - 手がかり: M1Ultra で E2E-iOS ios-inapp「ジェスチャ」S0010 を回し、`fm.gateWait*` と所要を見る
- **Compose・Flutter では、DSL / ft_batch の `type` / `clearInput` が入力欄でない要素を先にタップし得る**(09-11 §19.2)
  - 症状: ネイティブ描画(UIKit / SwiftUI / RN / Android View)は撃つ前に断るようにした(`StepExecutor.nonTextInputPreflightRefusal`)。
    自前描画では本物の入力欄が `button` 等で報告されうるので型名で断れず、ボタンを指すと押してしまう。MCP の ft_type は
    `TypeReadback.isTextInput` で撃つ前に断るので、自前描画では MCP と DSL の判断が割れたまま
  - 手がかり: 自前描画で「確実に入力欄でない」を言える別の根拠(a11y の editable 属性・ブリッジの申告)を探す
- **文字だけが描画されない Simulator を検知できない**(09-06)
  - 症状: 木は正常でも絵に文字が1つも出ずタイマーも進まないデバイスを凍結と判定できず、シナリオの赤としてだけ残る
  - 場所: `Sources/FTCore/FrozenVerdict.swift:17-43`(根拠の6種にこの形が無い)
  - 手がかり(案の段階): ラベルを持つ要素の領域を OCR で読み、どれも読めないときに疑う。入れるなら警告から
    (`isConclusive=false`)、`FrozenInjection` で陽性対照を通す

## MCP

- **`ft_type`(replace / clear-only)が検証の読み直しの後で古い ref を使う**(09-06・推測)
  - 症状: `snapshotAfter: true` で Enter が無いと `verificationSnapshot()` が新しい世代を採り、その後で先に解いた `targetRef` を
    新しい世代の base で native ref に戻すので、clear-only の枝の tap が別の番号を撃ち得る。`reproductionNote` も黙って消える
  - 場所: `Sources/fleetest-mcp/MCPServer+ScreenTools.swift:185-195`・:282→:290・:296、`MCPServer+Dispatch.swift:951`
  - 手がかり: tap と注記を merge の前に済ませるか、`generationSnapshot(containing:)` で ref の世代を引く
- **容器の縁にまたがる行への ft_tap が無警告で done になり外れる(DSL は内側へ寄せる)**(09-11・推測)
  - 場所: `Sources/FTCore/TapTargetGeometry.swift:172`(`outsideDeclaredScroller` は容器と全く交差しないことが条件)・:260-281、
    DSL の寄せは `StepExecutor+Actions.swift:547-555`(`straddleJump`)、MCP は `MCPServer+Snapshot.swift:1023-1042`
  - 手がかり: 判定と寄せを FTCore で共有する(MCP と DSL の判断が割れている)
- **iOS で別ウィンドウの全画面モーダル・上部バナーの裏を無警告で撃つ**(09-11・推測)
  - 症状: 木に載らない別ウィンドウを申告する `overlayWindowFrames` を返すのは Android だけ。バナーに覆われた `#btn_back` も
    無警告で撃ち、注記は SpringBoard のダイアログを疑う(`systemDialogHint(engine:)` は照会の結果を知らない)
  - 場所: `AndroidRunner/.../SnapshotBuilder.java:316`、`Sources/fleetest-mcp/MCPServer+Snapshot.swift:924-953`、
    `MCPServer+Driver.swift:1567-1574`
  - 手がかり: iOS のランナーにも窓の申告を足す(版上げ)。注記は照会の結果を受け取って出し分ける
- **キーボードで押し上げられてステータスバーの下に入った要素を、done のまま外す**(09-11・推測)
  - 場所: ステータスバーの帯を見る判定が MCP・`TapTargetGeometry`・`RefGuard` のどこにも無い。`suspectedHiddenUnderChrome`
    (`TapTargetGeometry.swift:444`)は覆う側が木にあることを前提にしている
- **キーボードで要素が木から消えたとき「画面が変わった」と言う**(09-11 M13)
  - 場所: `Sources/fleetest-mcp/MCPServer+Snapshot.swift:1010-1026`(`keyboardRefusal` は `.ghost` / `.found` のときだけ)、
    `RefGuard.swift:170`
  - 手がかり: `.gone` でもキーボードが出ていればキーボードを名指しする
- **ID の無い画面で方向セレクタを候補に出さない**(09-11 M14)
  - 場所: `Sources/FTCore/SelectorNaming.swift:185-264`(候補に相対セレクタ(`anchor:below` 等)が無い)
- **確認ダイアログが出ても `ft_open_url` が「Delivered」と返す**(09-11)
  - 場所: `Sources/fleetest-mcp/MCPServer+SessionTools.swift:269-282`、自動了承 `BridgeClient.acknowledgeOpenURLConsent`
    (`Sources/FTBridgeClient/BridgeClient.swift:488-517`。戻り値が Void で、(simulator, bundleId) ごとに1回・bundleId が無いと試さない)
- **プロファイル無し・`port:` だけで指定した iOS Simulator の `ft_run_scenario` が MCP の印を書かない**(09-11 §19.15)
  - 場所: `Sources/FTBridgeClient/PortDirectIOSTarget.swift:30`、`Sources/fleetest-mcp/MCPServer+ScenarioTools.swift:249`
  - 手がかり: `.fleetest/bridge-<port>.device` 等からポートに結び付いた UDID を引いて鍵にする
- **WebView の通常の行間で `webViewGapNote` が出る**(09-11・推測)
  - 場所: `Sources/FTCore/TreeCoverage.swift:33`(8%)・:44(長辺の 5%)。再現した画面が分からず、今も発火するかは未確認

## 録画・モニター・拡張

## CLI・その他

- **appName とアイコン名の食い違いの警告が Android には無い**(09-11 §19.7)
  - 場所: `Sources/FTCore/RunProfile.swift:1508`(`if platform == "ios"`)
  - 手がかり: aapt / aapt2 の `dump badging` の `application-label` で候補を採る(無ければ黙る)
- **E2EAppAndroid でディープリンクで起動したプロセスを回転させると、リンク先へ戻される**(09-11・SUT 側)
  - 場所: `E2EAppAndroid/app/src/main/kotlin/com/ftester/e2e/android/MainActivity.kt:64`(`handleDeepLink(intent)` を無条件に呼ぶ)
  - 手がかり: 構成変更(`lastCustomNonConfigurationInstance` が非 nil)のときは呼ばない。回転を挟む witness を1本足す

## 判断できない・確かめ方だけあるもの

- **起動し直した MCP から、背面で suspend した in-app アプリへの `ft_launch` が届くか**(09-06)
  - 確かめ方: Simulator で in-app で起動 → `ft_navigate home` → MCP を起動し直す → `ft_launch`(port 指定あり・なし)
  - 場所: `Sources/fleetest-mcp/MCPServer+SessionTools.swift` の `ftLaunch`、`MCPServer+Driver.swift:782` 付近、
    `Sources/FTBridgeClient/InAppDriver.swift:31`
- **`ft_status` で Android が複数台あるとき、読み取りのはずの一覧が全台で `startBridge` を通る**(09-06・症状は推測)
  - 確かめ方: ブリッジの無い Emulator を2台つなぎ、`ft_status platform:android` の前後で pidof を比べる
  - 場所: `Sources/fleetest-mcp/MCPServer+Hints.swift:186-203`、`Sources/FTAndroid/AndroidBridge.swift:190`・236
- **焦点救済の例示が別の欄を指す**(09-11 M16): どの文言を指した指摘か特定できない。今の注記
  (`MCPServer+ScreenTools.swift:210-221`)は実際に送った欄を名指ししている
- **シートのヒントが普通のリストでも出うる**(09-11 M10・推測): bf07926c で「容器の下端が画面下端に接し、上端が上から 1/4 より下」
  に絞った(`Sources/FTCore/StepExecutor+ScrollSearch.swift:13-39`・:722-729)。この形の普通のリストでは今も出うる
- **実物の 45 秒級 snapshot で SlowSnapshotBudget が効くことは未確認**(09-08): 注入(`FT_FAKE_SNAPSHOT_DELAY_MS=65000`)でしか
  確かめていない。修正後の実物の最大は 32 秒。結果 JSON に `slow-snapshot` かつ `snapshotMs` ≥ 45000 のステップが出たら、
  120 秒の打ち切りでなく中身のある失敗で終わっているかを見る(`Sources/FTCore/SlowSnapshotBudget.swift:23`)
- **再起動直後の冷えた xcuitest 供給の陽性対照**(09-11 §19.25): 修正は入っている(`Sources/FTBridgeClient/BridgeStartupWait.swift:10`・
  `BridgeProvisioner.swift:1546`)。docs/verification.md の「再起動直後の最初の xcuitest 供給」の節のとおり、Mac 再起動直後に
  `--cmp --ios-xcuitest` を回し、「booting the simulator before starting the xcuitest runner」が出て全滅しないことを見る
- **素の Ctrl-C でのリモートの dispatch.lock の対照**(09-11 §18.3): 中断の窓は §19.21 で直したが、実地の対照は未実施

## 設計判断で据え置いているもの(直さないと決めた。症状が出たら見直す)

- `activateSnapshotNode` の古い木: 撃つ前に `isReachable` で照合するが、UIView まで辿れないノードは許可する
  (`InAppBridge.swift:776-777`)ので、SwiftUI の AX だけのノードでは古いノードが発火し得る
- `InAppSettle` は keyWindow だけを見る(`InAppSettle.swift:91-99`)。別の窓のアニメは見ない
- CLI の `tap --ref` が画面外でも ✅: CLI の tap は状態を持たず、撮り直すと ref が振り直されて利用者が見た番号の意味が変わる
- dry-run の `--device` の黙殺: 機械ごとの子 run へ渡す内部向けのフラグで、断ると内部の経路を壊しうる
- `api bridge-sources` の平文・`remote status --json` の `"-"`・引数なし `doctor` のブリッジ停止: 仕様どおり
- I4 の DSL 側(XCUITest の DSL で ref を撃つと XCTest が拒否ボタンを押す)・DSL の tap のキーボード下: 断るのは MCP だけと決めた
