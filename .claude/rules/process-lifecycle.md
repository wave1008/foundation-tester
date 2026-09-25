---
paths:
  - "Sources/FTBridgeClient/BridgeEndpoint.swift"
  - "Sources/FTBridgeClient/BridgeProvisioner.swift"
  - "Sources/FTBridgeClient/BridgeReadyLedger.swift"
  - "Sources/FTBridgeClient/BridgeToolchainLedger.swift"
  - "Sources/FTBridgeClient/XCUIBridgeResolver.swift"
  - "Sources/FTCore/ParentDeathWatch*.swift"
  - "Sources/FTCore/ParentDeathWatch.swift"
  - "Sources/FTCore/ProcessLiveness*.swift"
  - "Sources/FTCore/ProcessLiveness.swift"
  - "Sources/FTCore/ScenarioHost.swift"
  - "Sources/FTCore/Shell*.swift"
  - "Sources/FTCore/Shell.swift"
  - "Sources/fleetest-*/main.swift"
  - "Sources/fleetest/ApiLiveCommand.swift"
  - "Sources/fleetest/InterruptRelay*.swift"
  - "Sources/fleetest/InterruptRelay.swift"
  - "Sources/fleetest/LiveBridgeAutoStarter.swift"
  - "Sources/fleetest/RunCompletionSweep.swift"
  - "Tests/FTBridgeClientTests/BridgeEndpointCorruptFileTests.swift"
  - "Tests/FTBridgeClientTests/BridgeEndpointTokenTests.swift"
  - "Tests/FTBridgeClientTests/BridgeReadyLedgerTests.swift"
  - "Tests/FTBridgeClientTests/BridgeToolchainLedgerTests.swift"
  - "Tests/FTBridgeClientTests/BridgeToolchainLedgerWiringTests.swift"
  - "Tests/FTBridgeClientTests/ProvisionLockTests.swift"
  - "Tests/FTBridgeClientTests/XCUIBridgeResolverPortHolderTests.swift"
  - "Tests/FTCoreTests/AvailableDataAutoreleaseScanTests.swift"
  - "Tests/FTCoreTests/ParentDeathWatchTests.swift"
  - "Tests/FTCoreTests/ParentDeathWatchWiringTests.swift"
  - "Tests/FTCoreTests/ProcessLivenessSourceScanTests.swift"
  - "Tests/FTCoreTests/ProcessLivenessTests.swift"
  - "Tests/FTCoreTests/ScenarioHostChildEnvironmentTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDeadlineExclusionTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDebugTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDryRunDetailTests.swift"
  - "Tests/FTCoreTests/ScenarioHostInstallArgumentsTests.swift"
  - "Tests/FTCoreTests/ScenarioHostPackageRootTests.swift"
  - "Tests/FTCoreTests/ScenarioHostRegisterChildProcessTests.swift"
  - "Tests/FTCoreTests/ScenarioHostRunnerUnavailableTests.swift"
  - "Tests/FTCoreTests/ScenarioHostSkipBuildStaleTests.swift"
  - "Tests/FTCoreTests/ScenarioHostWatchdogDurationTests.swift"
  - "Tests/FTCoreTests/ScenarioHostWatchdogExitedChildTests.swift"
  - "Tests/FTCoreTests/ShellSourceScanTests.swift"
  - "Tests/FTCoreTests/ShellTimeoutTests.swift"
  - "Tests/FTCoreTests/StreamingHelperAutoreleaseScanTests.swift"
  - "Tests/FleetestTests/ApiLiveCommandBudgetTests.swift"
  - "Tests/FleetestTests/CrossLayerTerminationTests.swift"
  - "Tests/FleetestTests/InterruptRelayEarlyRegistrationWiringTests.swift"
  - "Tests/FleetestTests/InterruptRelayTests.swift"
  - "Tests/FleetestTests/LiveBridgeAutoStarterPortHolderTests.swift"
  - "Tests/FleetestTests/ProvisionLockStartupPathsSyncTests.swift"
  - "Tests/FleetestTests/RunCompletionSweepWiringTests.swift"
  - "Tests/FleetestTests/StaleLedgerSweepTests.swift"
  - "vscode-fleetest/src/orphanSweep.ts"
---

# プロセスの生存管理(終了猶予・Shell.run・台帳) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **終了猶予の方針は1つ**(Codex 指摘 2026-09-06): **自前の後始末を持つ fleetest のプロセス**
  (`api run` / `run --runner` の子 / `fleetest-scenarios` = 終了スクリプト・dispatch.lock の解放・
  向きの復元)には**時限の SIGKILL を送らない** —— SIGTERM を送って待ち、刺さったら人が強制終了する
  (`InterruptRelay` の fleetest の子 = `escalateAfter: nil` / `ParentDeathWatch` = SIGTERM のみ /
  拡張の `api run` キャンセル = SIGTERM のみ + 2 秒経っても生きていれば「強制終了」ボタンを出す)。
  **時限 SIGKILL(2 秒)を送ってよいのは後始末を持たない外部・ヘルパーだけ**(ssh・`Shell.run` の
  外部コマンド・配信ヘルパー・`api monitor` / `host-metrics` / `api live serve` = stdin EOF で即終わる)。
  **拡張も同じ方針**: 起動時の孤児掃除(`orphanSweep.ts` の `orphanSignal`)と「全て終了して閉じる」(`planResidentKill`)は
  `api run` / `run`・シナリオ実行バイナリ(`fleetest-scenarios-<project>` = 分類は汎用型なのでコマンド名で見る `hasOwnTeardown`)に
  SIGTERM だけを送る(Reload Window 直後の run は ParentDeathWatch で後始末中なので、SIGKILL は
  録画の確定・teardown・run.json を刺し殺す)。後始末を持たないヘルパーは従来どおり SIGKILL。刺さった run は人が止める。
  「全て終了して閉じる」はホスト側のモーダルで確認し、`bridge down` が断ったらブリッジ系を SIGKILL しない
  **割り込みの登録(`InterruptRelay.observing`)は手元の dispatch.lock を取る直前 = setup.sh・供給・ビルドより前**
  (run / api run とも1プロセス1回。recorder はビルド後に `attachRecorder` で後付け・オーケストレータは
  `attachLateSubscriber` で合流・`LocalDispatchLock.acquire(interruptCheck:)` に同じ状態を渡して待機用の2組目を立てない)。
  段の境目で中断を見て既存の早期失敗の出口で抜ける(teardown・ロック解放は defer)。遅く登録すると、その間のシグナル
  (fan-out の子は ssh 切断の SIGHUP)が OS 既定の即死になり、teardown が走らず dispatch.lock が死んだ pid のまま残り、
  孤児のビルド・供給と次の run が重なる(`InterruptRelayEarlyRegistrationWiringTests`)→ maintainer-notes §51。
  **限界: `swift build` の実行中の中断は、ビルドが終わってから拾う**(ビルドの子は interruptState に登録していない)
  **階層をまたぐ保証(起こした側 → `api run` → シナリオ実行バイナリ)は `CrossLayerTerminationTests` が
  実バイナリで固定する**(`--dry-run --debug --pause-on-start --skip-build` = デバイスも入れ子の swift build も
  要らない長生きの孫。親の SIGKILL と子への SIGTERM の両方)
- **シナリオの watchdog(`ScenarioHost`)は打ち切る前に子の生存を見る・時計は SuspendingClock**
  (親の一時停止・Mac のスリープからの再開で、終わっていた緑の子を timeout の赤に書き換えていた。
  `ScenarioHostWatchdogExitedChildTests`)→ maintainer-notes §32
- **`Shell.run` は子孫ごと止め、出力の EOF を待ち切らない**(Codex 指摘 2026-09-05): timeout の
  SIGTERM/SIGKILL は `killpg`(Foundation.Process の子はグループリーダー)で孫まで届かせる ——
  `kill(pid,…)` だけだと `trap '' TERM` を継いだ孫がパイプを握り続けて 30 秒返らなかった。
  出力の回収は子の reap 後 `Shell.outputDrainGraceSeconds`(1 秒)で打ち切る(EOF が遅れるのは
  孫が書込端を継承したまま残る形だけ。`(sleep 3) &` の孫で 3 秒待っていた)。
  **`readDataToEndOfFile` を子プロセスのパイプに使わない**(EOF まで戻らない = 期限が置けない。
  `ShellSourceScanTests` が Sources 全体で落とす。対話プロンプトへ答える子は `Shell.run(stdin:)`)。
  **`availableData` を読むループは1回ごとに `autoreleasepool` で区切る**(返る NSData は自動解放で、
  抜けないループ・`Thread`・長く生きる readabilityHandler の中では1つも解放されない。拡張が1日じゅう
  生かす `api monitor` が 1 時間に約 630 MB 溜めた。`AvailableDataAutoreleaseScanTests` が Sources 全体で落とす)。
  **同じ規律は「1周ごとに画像を作る常駐ヘルパー」にも要る** ——
  `fleetest-devicepoll` の取り込みループは `URLSession` / `adb` の `Data` と Core Graphics の
  中間物(CGImage / CGImageSource)を毎周作るのに pool が無く、**1 時間 15 分で 71 GB(≒ 55 GB/時)**
  溜めて物理 192 GB の Mac をメモリ不足にした(2026-09-22。`api monitor` の 630 MB/時 と同型だが
  **画像なので桁が2つ違う**)。**`sleep` は pool の外に置く**(待っている間 1 周ぶんを抱えない)。
  ObjC のヘルパー(`fleetest-simstream` / `fleetest-androidstream` = `main.m`)は `@autoreleasepool` で
  main 全体を囲む慣例で守られており、**欠けていたのは Swift の `main.swift` だけ**だった ——
  Swift のトップレベルには pool が1つも無い。`StreamingHelperAutoreleaseScanTests` が
  取り込みヘルパーの集合と「画像を作る行が pool の内側にあること」を固定する → maintainer-notes §43。
  **グループの残存は直接の子の終了と独立に見る**(Codex 指摘 2026-09-06: 子が SIGTERM で素直に
  終わっても `trap '' TERM` の孫は残る。猶予が尽きたら `killpg(pgid, 0)` で残りを確かめ SIGKILL)。
  witness は `ShellTimeoutTests` の孫3本
- **プロセスの生存管理は3つの定義元に寄せる**(2026-09-05 の掃討): ①**生死の判定は
  `FTCore.ProcessLiveness.isAlive`**(sysctl で `SZOMB`・`P_WEXIT` を「死」と見る。`kill(pid, 0)` は
  ゾンビにも成功するので台帳が永久に回収されない —— `ProcessLivenessSourceScanTests` が素の
  `kill(x, 0)` を落とす。例外は自分の子を SIGKILL する直前の確認だけ)②**子は親の死で自ら終わる**
  (`FTCore.ParentDeathWatch`。spawn 側が `FT_PARENT_PID` を渡した子だけが kqueue で親の EXIT を待ち、
  SIGTERM → 2 秒で `_exit`。**opt-in** = 端末のシェルから `fleetest run &` した親が閉じても run を
  巻き込まない。`Process()` で `fleetest` / `fleetest-scenarios` を起こす経路を足したら
  `ParentDeathWatch.childEnvironment()` を渡す —— `ParentDeathWatchWiringTests` が集合を等号で固定。
  **例外は `warm-ocr` と背景の掃除(`RunCompletionSweep`)の2つ**: どちらも親の死を生き延びないと目的を果たせない(コンパイルのコミット / 親の run は掃除より先に必ず終わる)。有限で自分で終わる。
  **親の死を知らせる発話は投げない API で書く**(`ParentDeathWatch.writeNotice` = fd に `F_SETNOSIGPIPE` を
  掛けた生の `write(2)`。失敗は黙って諦める)—— 親が死んだ瞬間の stderr は**読み手の居ないパイプ**で、
  `FileHandle.write` は EPIPE を ObjC 例外にするので abort し、**SIGTERM に到達せず後始末が1つも走らない**
  (2026-09-16 の負荷テストで実測。9/05 以来ずっとこの形だった)。**この経路のテストは子の出力を
  パイプ/FIFO にする** —— ファイルへリダイレクトすると write が失敗せず、砦が1度も踏まない
  → maintainer-notes §24)
  ③**台帳(`.fleetest/bridge-<port>.pid/.inapp/.endpoint/.device/.toolchain/.ready`)はプロセスの実体で掃除し、
  中身は読む側が検証する**(`.endpoint` の1行目 = host が URL に使えなければ「記録が無い」へ倒す
  = `BridgeEndpoint.isUsableHost`。**台帳由来の文字列を強制開封しない** —— 壊れた1行が
  `URL(string:)!` でプロセスごと落とし、そのポートを開く `bridge status` も fleetest-mcp も
  道連れになった)
  (`StaleLedgerSweep` = provision の入口。`.inapp` は LISTEN 実体の有無、`.endpoint/.device` は
  対の `.pid` の生死。**`/status` 応答で生死を決めない**)。
  **`.ready` は「このランナーが一度でも準備完了になった」**(`BridgeReadyLedger`。起動しきれない
  ランナーの掃除が止めてよいかの門)で、**中身の pid が今の `.pid` と一致するときだけ数える**
  (ポートは同じ番号で建て直されるので、在否だけだと前世代の印が新しいランナーを守る → maintainer-notes §51.11)。
  **`.toolchain` は「そのブリッジを建てたツールチェーン」**(`BridgeToolchainLedger`)で、
  **生きているブリッジを再利用してよいかの門**。守る規律4つ: **①起動より前に控える**
  (ready の後に書くと、別プロセスが `.adopt` で引き取るときに「控え無し」を見て**正常な
  ブリッジを止める** —— 引き取る側は `/status` が答えた瞬間に見に来る)/ **②成果物側の指紋
  (`<DerivedData>/.toolchain`)と比べない** —— 成果物は `runnerRebuildReason` が後から独立に
  建て直すので「ディスクは新しいがプロセスは古い」を検出できない / **③`.reuse` と `.adopt` の
  両方で見る**(建て直しの判定が走るのは**建てるとき**だけなので、生きたブリッジはここでしか
  捕まらない)/ **④リースのある台は止めない代わりに1行言う**(`hasForeignLease` は run と MCP の
  印を両方数える。止めると他プロセスの run を壊すが、版の違うブリッジを駆動している事実は
  黙らない)。仕分けは `BridgeToolchainLedger.decide` の1箇所 → maintainer-notes §3.8。
  採番は `ProvisionLock` の内側でだけ行う
  (`provision` / `XCUIBridgeResolver` / `LiveBridgeAutoStarter` / **`ApiLiveCommand`**(要求された台の
  ブリッジがどこにも無いとき空きポートを充てる)の4経路。`ProvisionLockStartupPathsSyncTests` が
  集合を固定する。**ライブ操作の1件は「選ぶだけで起動しない」= 予約ではない**ので、
  起動までに埋まったら `LiveBridgeAutoStarter` が占有者を名指しして諦める)。拡張の孤児掃除(`orphanSweep.ts`)は配信
  (`api device-stream`・`fleetest-*stream` / `devicepoll`)も対象。**殺すのは PPID=1 かつ環境に
  `FT_PARENT_PID` を持つもの(= 拡張 / fleetest が起こしたもの)だけ** —— 手で `nohup` した同名の
  プロセスはコマンド文字列では区別できないので、所有の印で絞る(Codex 指摘 2026-09-05)
