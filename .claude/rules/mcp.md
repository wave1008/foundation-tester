---
paths:
  - "Bench/**"
  - "Scripts/bench-summary.mjs"
  - "Scripts/mcp-bench.sh"
  - "Scripts/stream_vs_poll_bench.py"
  - "Sources/FTAndroid/AndroidBridge.swift"
  - "Sources/FTAndroid/AndroidDriver.swift"
  - "Sources/FTBridgeClient/BridgeDiscovery.swift"
  - "Sources/FTBridgeClient/HybridFallbackIdentity.swift"
  - "Sources/FTBridgeClient/InstalledAppCheck.swift"
  - "Sources/FTBridgeClient/LaunchPreflightDriver.swift"
  - "Sources/FTCore/AppDriver.swift"
  - "Sources/FTCore/ArgumentBounds.swift"
  - "Sources/FTCore/BridgeDTO.swift"
  - "Sources/FTCore/BridgeIdentityCheck.swift"
  - "Sources/FTCore/Flow.swift"
  - "Sources/FTCore/StaleFrameDetector.swift"
  - "Sources/FTCore/TapTargetGeometry.swift"
  - "Sources/FTDSL/ValueAssertions.swift"
  - "Sources/fleetest-mcp/**"
  - "Sources/fleetest-mcp/DeviceSession.swift"
  - "Sources/fleetest-mcp/NoteCatalog.swift"
  - "Tests/FTAndroidTests/AndroidDriverCheckedInt32Tests.swift"
  - "Tests/FTAndroidTests/AndroidDriverTypeSplitTests.swift"
  - "Tests/FTBridgeClientTests/BridgeDiscoveryTests.swift"
  - "Tests/FTBridgeClientTests/HybridFallbackIdentityTests.swift"
  - "Tests/FTBridgeClientTests/InstalledAppCheckLaunchGuardTests.swift"
  - "Tests/FTBridgeClientTests/InstalledAppCheckVerdictTests.swift"
  - "Tests/FTCoreTests/BridgeIdentityCheckTests.swift"
  - "Tests/FTCoreTests/DriverErrorMessageTests.swift"
  - "Tests/FTCoreTests/StaleFrameDetectorTests.swift"
  - "Tests/FTCoreTests/TapTargetGeometryIsPointOnScreenTests.swift"
  - "Tests/FleetestMCPTests/**"
  - "Tests/FleetestMCPTests/ArgumentBoundsTests.swift"
  - "Tests/FleetestMCPTests/DeviceIndependentToolsIgnoreTargetTests.swift"
  - "Tests/FleetestMCPTests/DeviceStateInvalidationTests.swift"
  - "Tests/FleetestMCPTests/NoteBudgetTests.swift"
  - "Tests/FleetestMCPTests/NoteCoverageTests.swift"
  - "Tests/FleetestTests/ArgumentBoundsLiveCommandTests.swift"
  - "Tests/FleetestTests/LiveControlExitParityTests.swift"
  - "docs/mcp-audit-rounds.md"
---

# MCP サーバ(ft_*)と Bench の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- MCP 監査ラウンドの回し方(**1ラウンド = 初見の「形」1つ。アプリ名は軸ではない**。
  軸①画面の形 / 軸②セッションの形・拾ったものを**バグ / 自作機構の欠陥 / 言い回し**の3つに
  分ける規律・**増設と検分は交互**・停止規則・台帳): docs/mcp-audit-rounds.md。
  **地図の反復監査は閉じた。天気サイトはもう足さない**(→ maintainer-notes §9)
- MCP の使い勝手の計測(まっさらなエージェントがタスクを終えられたか・何手かかったか):
  Bench/README.md(`Scripts/mcp-bench.sh`)。**実 web ページの形も盤面で測れる**
  (`Bench/boards/` に HTML を置きホストで配信。**ライブの web は叩かない** = 盤面が毎日変わると
  手数の差が注記の効果と混ざる)。**手数は注記の有無で動かないと分かっている**ので
  (代替手段の無い盤面でも 5/5 完了。Bench/measurements.md)、**足す/消すの判断材料は
  note B(実現バイト)**。`NoteBudgetTests` の**本数と鍵の集合の等号固定**は
  引き続き効かせる(予算を動かすには根拠を台帳へ書く)
- **診断のために外部コマンドを撃つ経路も、協調スレッドプールにブロッキングを載せない**
  (ft_status の udid 診断が全ポートへ `lsof` を同時に撃ってプールを塞ぎ、200 秒返らなくなった。
  台帳から候補を絞る → `ps` 1 回 + `isBound` 数本で 1.2 秒)→ maintainer-notes §27
- **引数の値域は `FTCore.ArgumentBounds` の1箇所**(MCP の `intArgument`/`doubleArgument`/
  `stringArgument` と、ライブ操作の `intField`/`doubleField`/`stringField` が同じ表を引く)。
  守る規律3つ: **①値域を持たない引数も `.unbounded` で表に載せる**(載せ忘れと「縛らないと決めた」を
  区別する。`ArgumentBoundsTests` がスキーマの数値プロパティ全数との包含を等号で固定)/
  **②検査は読む場所ではなく `MCPServer.call` の入口で全数**(`waitSeconds` のように条件付きでしか
  読まれない欄は、読まれない回に 0/負が通って「効いた」と誤解させる)/ **③`ft_batch` の DSL 行も
  同じ表を通す**(あちらは `intArgument` を経由しない)。必須の文字列は空文字・空白のみを断る
  (省略は断らない = 呼び手ごとに既定が違う)→ maintainer-notes §44.2。**長押し・ジェスチャの秒数は
  既定 10 秒まで、コマンドの `maxGestureSeconds:` 引数でその1回だけ最大 60 秒まで上書きできる**
  (ユーザー決定 2026-09-24)。**方針の判定(既定10・上書き上限60)はホスト側**(DSL は
  `StepExecutor.executeAction` の入口 = `FlowStep.gestureDurationViolation`・MCP/ライブ操作は
  `ArgumentBounds.gestureCapViolation`)。**定義元は `BridgeAPI.defaultMaxGestureSeconds` /
  `BridgeAPI.gestureSecondsCeiling`**。
  **ランナー(iOS)と Android の注入層は 60 秒(ceiling)を絶対上限として最後に断る**
  (要求ごとの上書きは受け取らない・ホストの門をどちらも通らない経路の最後の砦。超過は
  testmanagerd が合成列を作り続けて肥大化する → maintainer-notes §49.1)。
  **同じ的を指す引数の併用(ref と x/y 等)は入口で断る**(`targetExclusivityViolation`)
- **失敗の「出口」(次の一手)を配る経路は MCP とライブ操作の2つ**。判定(`BridgeDiscovery.probeStatus` /
  `DriverError.isNoReadableWindow` / `FTCore.StaleFrameDetector` 等)は FTCore・FTBridgeClient に1つ置いて
  共有するが、**それを呼んで文言にするのは呼び手ごと** —— **片方にだけ配線すると、同じ状況で一方は
  出口を案内し他方は一次情報しか返さない**(実際にこの形で同じ型の不具合が3回続けて出た。
  直すたびに MCP にだけ足していた → maintainer-notes §45)。**run(DSL)は別扱い** —— あちらは失敗を
  レポートへ残して自動回復する経路で、人がその場で次の一手を打つ場ではない。集合は
  `LiveControlExitParityTests` が等号で固定する(**走査はコメントを落としてから** = 判定の名前は
  doc コメントにも出るので、素のまま検索すると配線を消してもコメントだけで通る)。
  **ライブ操作の文言は人間向け**(拡張の UI を触っている人が読む)なので、MCP のエージェント向けの
  文言をそのまま写さない。**CLI 側だけ直しても受け手には届かない** —— 観測に注記を足したら
  `notes` 欄と ProtocolVersion、拡張の表示まで通す
- **hybrid の予備(XCUITest)ポートも使うたびに本人確認する**(`FTBridgeClient.HybridFallbackIdentity` を
  MCP のキャッシュ命中とライブ操作の命令ごとが共有。主の udid だけ見ると、建て直しで予備ポートが別の台・
  in-app に化けても home/drag を撃ち続ける。**`BridgeIdentityCheck.verdict` は udid が両側にあるとエンジンを
  見ない**ので、エンジンの決まった片側は `hybridFallbackDrift` で先に見る)。**ずれは3値で扱う** (`BridgeIdentityCheck.HybridFallbackDrift`: none / sameDeviceEngineChanged / differentDevice)—— **別の台(differentDevice)は ref の有無を問わず断り、記憶を捨てない**(捨てると次の同じ呼び出しが `keyChangedDevice` の previous=nil を通って黙って別の台に固定される。抜けるのは呼び手が `udid` を明示したとき)。ライブ操作も別の台なら同じポートで作り直さず、そのコマンドを撃たずに失敗を返す。**udid の診断が予算切れなら
  「確認できなかった」と言い、不在も `bridge up` も言わない**(`diagnosisTimedOut`)→ maintainer-notes §51
- **座標を整数へ畳む所は trap しない側に倒す**(座標は `.unbounded`。入口の画面内判定
  `TapTargetGeometry.isPointOnScreen` は MCP とライブ操作が共有するが、DSL も届くので最後の砦
  `AndroidDriver.checkedInt32` は別に要る)
- **MCP の engineKey ごとの記憶は `DeviceSession`(`Sources/fleetest-mcp/DeviceSession.swift`)の欄だけ**。
  `MCPServer` の `drivers` / `lastSnapshots` 等は `sessions` を見る窓(`SessionMap` / `SessionFlags`)で、
  `forgetDeviceState` はセッションを丸ごと捨てる。**並列の `[String: …]` / `Set<String>` を戻さない**
  (束ねる前は集合型の2つが後始末から漏れていた。`DeviceStateInvalidationTests` が落とす)。
  **udid → port の畳み込みはスキーマに `udid` を宣言したツールでだけ撃つ**(`toolFoldsUDID`。
  `ft_logs` はブリッジが死んだ後に読むツールなので走査で落とさない)
- **宛先(udid/serial/port)を取らない MCP ツールで宛先を解決しない**(`toolAcceptsDeviceTarget` の
  分岐1箇所)。畳み込み(`foldingUDIDIntoPort`)はブリッジ走査を撃ち、居なければ落ちるので、
  1台を駆動している呼び手(`udid` を毎回添える)はブリッジが死んだ瞬間に**一覧・診断のツールまで
  道連れ**になり、文面が案内する `ft_list_devices` 自身が同じエラーを返す袋小路になる
  (実地 2026-09-23 → maintainer-notes §46.5)。集合は
  `DeviceIndependentToolsIgnoreTargetTests` が等号で固定する
- **MCP(`ft_*`)は DSL と別経路なので、鮮度・防御を DSL 側に入れただけでは届かない**
  → maintainer-notes §5。**ただし同じ判定をそのまま強い挙動へ流用しない**。探索ロジックは
  **MCP に2つ目の実装を書かず `StepExecutor` へ委ねる**(`ft_scroll_to`)。
  **逆に、同じ門が両側にあるなら倒す向きも揃える** —— 未インストールのまま
  `XCUIApplication.launch()` を撃つとハンドラが 60 秒で自壊してブリッジごと消えるので、
  `ft_launch` の門(`MCPServer.launchGuardDecision`)は DSL の `LaunchPreflightDriver` と同じく
  **「確かめられないなら撃たない」**側に倒す(在否は udid で引く =
  `InstalledAppCheck.simulatorInstallVerdict(udid:)`。**素通しでよいのは Android と in-app
  エンジンだけ** = ランナーが死なない経路。`com.apple.springboard` は launch しないので門の外)。
  **判定は `InstalledAppCheck.launchGuard` の1箇所で、MCP の `ft_launch` と
  ライブ操作(`api live serve` の `launch` / `activate`)が共有する** —— ライブ操作に門が無かったため、
  空文字列や端末に無い bundleID を渡すと**そのコマンドが 30 秒刺さって watchdog が serve を
  force-quit し、健全なブリッジまで建て直しになった**(T1 と同じ型の掃討漏れ → maintainer-notes §42.7)。
  **ライブ操作の NDJSON は型違いを黙殺しない** —— `cmd` が読めた行は
  `{"kind":"actionResult","ok":false,"error":"<欄> must be …"}` を返す(文言は MCP の
  `intArgument`/`doubleArgument` と同じ)。黙殺すると拡張は応答を待って固まり、serve の再起動に至る。
  JSON でない行・`cmd` の無い行だけが従来どおり黙殺の対象
- **木だけから決まる注記は `Sources/fleetest-mcp/NoteCatalog.swift` が唯一の定義元**
  (`NoteCoverageTests` のソース走査が検出)。目録にすると3つ手に入る: **発火の全数計測** /
  **鍵ごとの黙らせ**(`FT_MCP_NOTES_OFF=<鍵,…|all>`)/ **出力バイトの回帰ゲート**。
  **注記を足すか消すかは読んだ印象で決めない** —— `Scripts/mcp-bench.sh` で手数が動いたかで決める
  (バグは有限だが「もっと分かりやすく言えたはず」は無限に出るので、印象で決める限り注記は
  単調に増える)。**「出ない」を削除の根拠にする前に、必ずアーキタイプを足して測り直す**。
  **フィクスチャの分類の正は `NoteCoverageTests.archetypes`**(接頭辞は OS を表すだけ)。
  **「地図でしか出ない」と見えた注記も、アーキタイプを足すと他でも出る**
  (`unlabeledClickablesNote` は settings、`keyboardCoverageNote` / `scrollFrameCandidates` は
  chat で発火した)。残る `truncationNote` / `ghostNote` は各1画面のみ、
  `bulkExemptNote` / `sliverNote` は0枚 —— 死に注記は理由を確かめて `knownSilent` に
  登録する(等号照合なので新しい死に注記は落ちる)。
  **1つのアーキタイプがコーパスの 60% を超えないこと**(`testNoArchetypeDominatesTheCorpus`)——
  深く掘るほど1アプリが増え、**掘るほど汎用性の判定が悪くなる**逆向きの力が働くので機械で止める
