---
paths:
  - ".claude/skills/fleetest-remote-setup/**"
  - ".claude/skills/fleetest-remote-setup/SKILL.md"
  - "Scripts/align.sh"
  - "Scripts/bench.swift"
  - "Sources/FTAndroid/DeviceBooter.swift"
  - "Sources/FTBridgeClient/BridgeDiscovery.swift"
  - "Sources/FTBridgeClient/BridgeLauncher.swift"
  - "Sources/FTCore/FMUsageLedger.swift"
  - "Sources/FTCore/LocalConfig.swift"
  - "Sources/FTCore/LocalStreamHolder.swift"
  - "Sources/FTCore/RemoteHostEntry.swift"
  - "Sources/FTCore/RunHooks.swift"
  - "Sources/FTCore/RunnerProfileView.swift"
  - "Sources/FTCore/ScenarioHost.swift"
  - "Sources/FTCore/StreamLease.swift"
  - "Sources/FTCore/StreamOwner.swift"
  - "Sources/FTCore/TransferIgnore.swift"
  - "Sources/FTRemote/**"
  - "Sources/FTRemote/DispatchOrder.swift"
  - "Sources/FTRemote/HostOccupancy.swift"
  - "Sources/FTRemote/ParentBoundCommand.swift"
  - "Sources/FTRemote/PipeLinePump.swift"
  - "Sources/FTRemote/RemoteDispatch.swift"
  - "Sources/FTRemote/RemoteDispatchDeviceScope.swift"
  - "Sources/FTRemote/RemoteDispatchLock.swift"
  - "Sources/FTRemote/RemoteDispatchQueue.swift"
  - "Sources/FTRemote/RemoteDispatchWait.swift"
  - "Sources/FTRemote/XcodeSelection.swift"
  - "Sources/fleetest/*Dispatch*.swift"
  - "Sources/fleetest/*Fanout*.swift"
  - "Sources/fleetest/*Remote*.swift"
  - "Sources/fleetest/ApiMonitor*.swift"
  - "Sources/fleetest/ApiMonitorCommand+DeviceState.swift"
  - "Sources/fleetest/ApiMonitorCommand.swift"
  - "Sources/fleetest/ApiRunCommand.swift"
  - "Sources/fleetest/ApiRunMachineFanout.swift"
  - "Sources/fleetest/BridgeDownRefusal.swift"
  - "Sources/fleetest/DeviceMachineRunner.swift"
  - "Sources/fleetest/DispatchPrelock.swift"
  - "Sources/fleetest/InterruptRelay.swift"
  - "Sources/fleetest/LocalDispatchLock.swift"
  - "Sources/fleetest/ProfileRunner.swift"
  - "Sources/fleetest/RemoteDeviceFanout.swift"
  - "Sources/fleetest/RemoteMonitorFanout.swift"
  - "Sources/fleetest/RemoteProjectSync.swift"
  - "Sources/fleetest/RemoteRunDispatcher.swift"
  - "Tests/**/*Dispatch*.swift"
  - "Tests/**/*Remote*.swift"
  - "Tests/FTAndroidTests/DeviceBooterOutcomeTests.swift"
  - "Tests/FTAndroidTests/DeviceBooterShutdownAllTests.swift"
  - "Tests/FTAndroidTests/DeviceBooterStopRefusalTests.swift"
  - "Tests/FTBridgeClientTests/BridgeDiscoveryTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherCaptureSettingsTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherNotRunningMessageTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherPidReuseTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherRebuildTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherStopTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherTokenInjectionTests.swift"
  - "Tests/FTCoreTests/DispatchOrderTests.swift"
  - "Tests/FTCoreTests/FMUsageLedgerTests.swift"
  - "Tests/FTCoreTests/HostOccupancyTests.swift"
  - "Tests/FTCoreTests/LocalConfigTests.swift"
  - "Tests/FTCoreTests/LocalStreamHolderTests.swift"
  - "Tests/FTCoreTests/ParentBoundCommandTests.swift"
  - "Tests/FTCoreTests/PipeLinePumpTests.swift"
  - "Tests/FTCoreTests/RemoteDispatchQueueTests.swift"
  - "Tests/FTCoreTests/RemoteHostEntryColorTests.swift"
  - "Tests/FTCoreTests/RemoteHostEntryFMConcurrencyTests.swift"
  - "Tests/FTCoreTests/RunnerProfileViewTests.swift"
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
  - "Tests/FTCoreTests/StreamLeaseTests.swift"
  - "Tests/FTCoreTests/TransferIgnoreTests.swift"
  - "Tests/FTCoreTests/XcodeSelectionTests.swift"
  - "Tests/FleetestTests/ApiRunMachineFanoutMultiplexerTests.swift"
  - "Tests/FleetestTests/DeviceMachineRunnerChildArgsTests.swift"
  - "Tests/FleetestTests/DeviceMachineRunnerMissingResultsTests.swift"
  - "Tests/FleetestTests/DispatchLockBeforeBuildOrderingTests.swift"
  - "Tests/FleetestTests/DispatchPrelockTests.swift"
  - "Tests/FleetestTests/InterruptRelayEarlyRegistrationWiringTests.swift"
  - "Tests/FleetestTests/InterruptRelayTests.swift"
  - "Tests/FleetestTests/ProfileRunnerFMSettingsTests.swift"
  - "Tests/FleetestTests/RemoteDeveloperDirWiringTests.swift"
  - "Tests/FleetestTests/RemoteDeviceFanoutTests.swift"
  - "Tests/FleetestTests/RemoteMonitorFanoutIDTests.swift"
  - "Tests/FleetestTests/RemoteMonitorFanoutRetryTests.swift"
  - "Tests/FleetestTests/RemoteProjectSyncTests.swift"
  - "docs/remote-runner*.md"
---

# リモート(SSH ディスパッチ・監視の fan-out・ロックと待機列・占有) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **リモートの純粋ロジック(SSH ディスパッチ・登録簿の解決・dispatch.lock・占有・setup 計画)は
  `Sources/FTRemote`**(利用側は fleetest CLI だけ。受け手のシナリオ実行バイナリにはリンクしない)。
  **FTCore から FTRemote を参照しない**(循環)—— `LocalConfig` が持つ登録簿のスキーマ
  `RemoteHostEntry` だけが FTCore に居る。他の分割は保留(理由は maintainer-notes §10)
- **用語(ユーザー決定。全体で一貫させる)**: **host = ホスト名 / IP**(ネットワークの実体)、
  **machine = その host に対するローカルエイリアス**(この Mac の登録簿だけが知る名前)。
  定義と4つの規律(①エイリアスをリモートへ出さない ②記録の鍵は host ③プロファイルに ssh 実体を
  書かない ④**手元の台帳をランナーの視点で書かない** = 他機の台に `machine: "local"` と書くと、
  ディスパッチが手元へ落ち、監視では実在する手元の同名機が id 衝突で消える)は
  docs/remote-runner.md §0。**エイリアスは頻繁に変わりうるので記録・登録の鍵に
  しない**(例外はその machine 自身に関する構成)。JSON キーはプロファイル `devices[].machine`・
  登録簿 `machine`・記録 `host`。**拡張 ⇄ webview のメッセージと CLI ⇄ 拡張のワイヤも `machine`**
  (ProtocolVersion 9。同時配布なので旧キーは読まない = **型検査の効かない webview 境界は
  往復テストで縛る**)→ maintainer-notes §3.1。
  リモートへ送るプロファイルは `FTCore.RunnerProfileView` が「そのランナーから見た姿」へ畳む
  (自分の台は `machine: "local"`・他機の台は削除)ので、**転送物にも引数にもエイリアスは出ない**
- **リモートのデバイスの監視と配信**: 手元の `api monitor` は simctl/adb = **この機械しか観測
  できない**。別の機械のぶんは `RemoteMonitorFanout` が
  `remote exec <runner> -- api monitor --device-machine local` を1本ずつ立てて合流させ、
  ライブ映像は**1デバイス = 1本の ssh**(`api device-stream` が向こうで宛先を解決し配信ヘルパーへ
  `execv` で化ける = stdout のバイト列が手元起動時と同一なので `StreamPipeline` をそのまま使える)。**多重化の枠は作らない**(却下理由は docs/remote-runner.md §13)。
  守る規律3つ: **①他の機械の台を走査しない**(仕分けは `ApiMonitorCommand.scope` が pure に持つ)/
  **②観測していない台は `state:"unknown"`** —— offline と別の値にする(同じにすると向こうで
  動いていても止まって見える。拡張の `MonitorDeviceState` と対)/ **③配信が張れなければ
  ポーリングへ落ちる**。**版が揃っていないと状態も映像も来ない**。
  **操作も同じ規律** —— 一括だけでなく**タイル1枚の起動・停止もその機械へ回す**
  (`--device-machine` を付けずに `api start-device --name` を撃つと、同名の台が別の機械にも
  居るとき**別の機械の設定でこの Mac にシミュレータが1台できる**、という事故を防ぐのがこの規律。
  `findDevice` は (machine, name) で引き、`--device-machine` 省略時に同名の台が複数の機械に
  居れば `.ambiguous` で断る —— 黙って手元を選びはしない)。
  **中継する側が machine を埋める**(3経路とも: `RemoteMonitorFanout.ingest` /
  `RemoteDeviceFanout.machineStamped` / `ApiRunMachineFanout` の rehost)—— 子は
  `--device-machine local` で走るので自分の台を `machine:null` と名乗り、そのまま流すと拡張が
  **同名の手元のタイル**を書き換える(機械ごとに2台ずつ起きていても「全体で2台」に見える)。
  **ブリッジ watchdog はリモートの台も見る**(2026-09-25)。成立の条件は2つ —— ①修復手段:
  lifecycle ジョブが machine を運び、リモートは `remote exec <machine> -- api start-device
  … --device-machine local` で回る ②記録の鍵を **`device.id`(machine 込みで一意)**にした
  (name 単位だった頃は「向こうの connected が手元のハングを隠す / 向こうの booted が手元の
  健全な台を再起動する」)。**webview へ出す `bridgeWatch` には machine を載せる**
  (省略 = 手元。落とすと `findTileByName` が同名の手元タイルに当たる)。
  **健全性 watchdog(`monitorHealthWatchdog`)はまだリモートを見ない** —— Wi-Fi 修復に
  相当する `api` の口が無く、そこだけ手元の adb 直叩きのため。実機はどちらの watchdog も
  見ない(供給に数分かかり枠を専有する。機械に依らない除外)。
  **ホストの負荷(MEM/CPU/GPU/VN/FM。VN = Vision / Core ML の呼び出し = OCR と画像分類器)も同じ** —— 拡張が
  `remote exec <runner> -- api host-metrics` を機械ごとに立て、ツールバーのグラフを
  **機械ごとの行**にする(左端は手元が `local`・以降は機械名。1行のときはラベルを出さない)。
  **行の集合は直近の monitorDevices に居る機械で決める**(表示フィルタは通さない = ssh の churn を
  作らない)/ **消えた機械の行は捨てる**(古い値を出し続けない)/ **機械名は spawn した側が付ける**
  (サンプル自身は持たない)。**FM も同じ行に乗る**が、host-metrics は FM を自分では叩かない
  (測る対象を自分で消費してしまう)—— **FM を呼んだプロセスが
  `~/.fleetest/fm-usage/<pid>.json` に置いた控えを毎 tick 読む**(`FTCore.FMUsageLedger`。
  機械グローバル = `api host-metrics` に `--project` が無い性質を保つ / 生存判定は **pid だけで
  mtime を見ない** / **読めない(不明)は null・呼び出し 0 件は 0** で混ぜない / 初見の pid は
  増分 0)。**run のイベントからは供給しない** —— 拡張が起こした run しか見えず、CLI 実行や
  他人の run が 0 に見えるため
- **ランナーの Xcode は発行側に合わせて自動選択する**(`FTRemote.XcodeSelection`。選択は
  `DEVELOPER_DIR` の export = **プロセス単位・sudo 不要**で、**`xcode-select -s` は使わない** ——
  機械全体に効くので共有ランナーでは他人の run を壊す)。守る規律4つ:
  **①照合(toolchain probe)と run は同じ解決を1回だけ通す**(別々に解決すると、照合した Xcode と
  実際に走る Xcode が食い違い、**緑のまま別の Xcode で走る**。`RemoteDeveloperDirWiringTests` が
  走査で固定)/ **②ちょうど1件一致のときだけ採る**(登録簿の pin > build 一致 > 製品版一致。
  0個・複数は候補を並べて拒否し、手近な Xcode へ黙って倒さない)/ **③候補を列挙できなければ
  ambient**(見えないだけで運用を止めない)/ **④モニターには効かせない**
  (`remoteExecCommand` の既定は nil。観測は dispatch.lock の**外**で常時 simctl を撃つので、
  版の違う simctl を同じ CoreSimulatorService に当てない)。**拒否の文言は原因で分ける** ——
  一致0個は「その Xcode を入れる」・複数は「pin する」で**対処が逆**。
  **toolchain 不一致そのものの仕分けは `RemoteCompat.verdict` の1箇所**(製品版が同じで build だけ
  違う = ベータ seed はディスパッチを止めない advisory・製品版違いと読めない指紋は blocking)
  → maintainer-notes §3.7・§3.8
- リモート実行(`run --runner` の SSH ディスパッチ):
  - **ssh 越しに何かを起動する経路を新設したら非対話 PATH の補正
    (`/opt/homebrew:/usr/local/bin`)を必ず写す**(既存は `RemoteShell.remoteRunCommand`)
  - **子プロセスを spawn する経路を足したら中断のリレーも足す**(`InterruptRelay`)。
    **async 文脈でパイプを行読みするときは `FTRemote.PipeLinePump`**(semaphore の `wait` を
    async 文脈に書かない = Swift 6 でエラー。同期関数の既存2箇所は据え置き)。
    **SIGKILL へのエスカレートは ssh にだけ**。**シグナルソースは1プロセスに1組**
    → maintainer-notes §3.2。`fleetest remote unlock` は自分の死んだディスパッチのロックだけを外す(`RemoteDispatchUnlock`)。**`--runner local` で手元のロックも外せる**(判定の軸は issuer ではなく **issuerHost** —— この機械が置いたロックは pid で確定・他人がここへディスパッチしたロックは**その run がこの機械に残っていないか**を pgrep で確かめる。**base を仮定して pgrep しない** = 別 base の生きた run を「居ない」と答えて守っているロックを外す)。**ロックの自動回収・unlock はランナー上でその run が生きていないことを確かめてから外す**(手元の pid が死んでもリモートの run は生きている)。**`-tt` の ssh は `ParentBoundCommand` で包む**(`kill -9` で親が死ぬと孤児の ssh がリモートの run を出力の write で止めたままにする)
  - **機械分担の run は手元の台の二重使用を、どの機械へも配る前に断る**
    (`ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch`。run / api run の2経路。子の中の拒否だけだと
    リモート分が走り続けて同時刻の別 run を弾く)→ maintainer-notes §32
  - **`--runner M` + 明示 `--device` は M の台に限定**
    (`RemoteDispatchExplicitDeviceScope`)。**`--runner local` も同じ判定を通す**
    (run / api run の2経路。絞らないと別ホストのエントリの UDID を手元で探して
    `no simulator with that UDID` で止まる)
  - **LPT はリモートでも実績で回る**: 実績 JSON は run のたびに常に回収・実績と観測窓は
    machine 別・フリート割り当ては facts キャッシュ(`.fleetest/remote-hosts/<host>.json`)で
    機械別に見積もる(実測は docs/performance-tuning.md §3.7)。**facts の machine 採取は
    relink より前** → maintainer-notes §3.3
  - 設計・却下案・セキュリティ前提は docs/remote-runner.md / **利用者向けの導入手順は
    docs/remote-runner-setup.md** / **エージェント向けは
    `.claude/skills/fleetest-remote-setup/SKILL.md`**(機械作業は `fleetest remote setup` に委ね、
    聞くこと・人手へ渡すこと・結果の読み方だけを持つ)。**片方だけ変えない** —— 手順に影響する
    変更(レイアウト・併用不可オプション・適合チェックの項目)は docs とスキルの両方に入れる
- **共有(複数ユーザー)の規律**(docs/remote-runner.md §18.7。M2 実装済み): **占有を知るために
  ssh を足さない** —— `dispatch.lock` はその機械のディスクにあるので、**向こうで走っている子
  (`api monitor` の fan-out)にローカルで読ませ**既存の NDJSON(`monitorLock`)に相乗りさせる
  (読む場所は `~/.fleetest` 固定・判定は `FTRemote.HostOccupancy` の1箇所)。
  **手元も同じ1行を出す**(手元の run も同じロックを取るので「ランナー機の文脈か」は占有と無関係。
  綴りは `machine` 欄の省略 = `monitorRuns` / `monitorDevices` と同じ手元の表し方)。守る規律4つ:
  **①「不明」と「空き」を混ぜない**(子が落ちたら `observed:false`。**控えは消さない** ——
  消すと「一度も聞いていない機械」= 配信してよい、と同じ形になり run の最中に配信が再開する。
  不明の間は**配信を畳んだまま・保持者は名乗らない**(`isConfirmedHeld` を通す)。
  不明を空きに倒すと破壊的操作の確認が「走っている run は無い」と誤って請け合う)/
  **②配信の退避は保持者を問わない**(自分の run でも干渉は同じ)**が、畳むのは配信だけで観測は続ける**。
  **自分の run のぶんだけは「デバイスモニター」タブの「ライブ更新」(既定 ON = 配信を続ける)で利用者が選ぶ**
  (ユーザー決定 2026-09-17。他人の run・観測できない機械は常に畳む。`streamFoldMachines`)。
  **OFF は run の有無を問わず全台の配信と画面の取り込みを止める**(負荷を下げる口。パネルが隠れたときと同じ
  `deviceStream.setVisible(false)`。ユーザー決定 2026-09-20)/
  **③二重配信は拒否でなく事実で止める**(`FTCore.StreamLease` の控えを監視が読んで
  `streamedByOther` を配り、拡張が起こさない。**起こしてから断る形にすると ssh の再試行ループ**
  になる。**同じ Mac の別ウィンドウは台帳でなくプロセスの実体で判定する** = `FTCore.LocalStreamHolder`
  が `ps -E` で同じ台のヘルパーを探し、最も早く起動した1本の所有者の印(`FTCore.StreamOwner` =
  拡張ホストが立てる `FT_STREAM_OWNER`。`RemoteShell` が ssh 越しに運ぶので**ランナー機の上でも
  同じ判定が走り、同じ利用者の2ウィンドウも止まる**。`FT_PARENT_PID` は運ばない)が自分と違えば
  `streamedByOther`。保持者は両方のウィンドウが同じ答えを出す規則で1本に決める)/ **④他人の run を殺す操作はロックを読む**(`remote clean` は中止・
  `--ignore-lock` で押し切る。**読めないときは通す** = 掃除が永久にできなくなるほうが害が大きい)。
  **台を止める操作も同じ**(`DeviceBooter.shutdownOne` / `shutdownAll` が実際に止める前に
  `deviceInUseRefusal` = run-lease と **MCP の印(`mcp-<鍵>.lease`)** の保持者を読む。文言は run と MCP で分ける。`api stop-device` / `stop-all-devices` / `restart-devices` /
  `wipe-device` / `devices down --profile` / **`bridge down`(`--port` / `--all` / `--platform android` の3経路とも)**
  の全部がここを通る。押し切るのは CLI の `--force` だけ)。**門は CLI の口にだけ置く** ——
  `BridgeLauncher.stop()` / `stopAll()` は供給と古いブリッジの掃除からも呼ばれるので、
  あちらに足すと run が建てられなくなる。**宛先が引けないときは通す**(無応答のブリッジを
  止められないと回復手段が無くなる)**が、「応答しない」を「死んでいる」と読まない** ——
  駆動中の XCUITest は操作の間 /status を返さない(quiescence 待ちで数十秒ブロックする実測がある)ので、
  **走査に載らないポートは `BridgeDiscovery.probeStatus` の4値で見て、断るのは本当に busy
  (`.timedOut`)のときだけ**(`BridgeDownRefusal.unresponsiveButBoundRefusal`。`--port` / `--all` の
  両経路。押し切るのは `--force`)。**「固まった転送」(`.transportFailed` = ブリッジが死んで
  iproxy だけがポートを握る)は断らない** —— 止めることが唯一の回復手段なのに「待て」と言い続ける
  袋小路になる(実地 2026-09-23 → maintainer-notes §46.4)。複数ポートは `probeStatuses` で並列に撃つ。
  鍵(udid)が引けない = lease も照合できないので、**いちばん使用中のときだけ門が開く**という
  逆向きの穴になっていた(実地 2026-09-22: MCP が操作中のブリッジが無言で止まり、そのセッションは
  「no running bridge」しか返さなくなった → maintainer-notes §42.5)。待受も無ければ従来どおり通す
  (固まったブリッジを止める手段を奪わない)。`bridge down --all` の判定は `BridgeDownRefusal.decide`
  (純粋関数。文言は `DeviceBooter` の既存関数から組み立て、新しい文言を作らない)
  **プロファイル無しの全掃討 `devices down` は台を選べないので、生きた run-lease か MCP の印が1本でもあれば
  掃討ごと断る**(`DeviceBooter.sweepRefusal`。判定はリモートへ分散する前。`--force` は子へ、
  `remote clean --ignore-lock` は `--force` として運ぶ)→ maintainer-notes §25。
  **モニターの「全て終了」は拡張が自分のライブ操作の serve を畳んで印が消えてから撃つ**
  (`LiveTabHost.suspendServeForSweep` → 掃討 → `resumeServeAfterSweep`。ライブ操作も MCP と同じ印を
  書くので、畳まないと全掃討がその印で丸ごと断られ何も止まらない → maintainer-notes §48)。
  **奪う口(`--force-lock` / `--force`)を GUI に出さない**。
  **ssh 越しのコマンドにグロブを書かない**(相手は zsh。`for w in <マッチ無し>` は**シェルごと
  落ちて後続の文が全部消える**)—— 一覧は `find … 2>/dev/null` で作る → maintainer-notes §3.5
- **1マシンで同時に走る run は1本**(ユーザー決定 2026-09-21「高負荷になりすぎてテストが不安定に
  なる」= 避けたい副作用ではなく**守りたい不変条件**)。`dispatch.lock` は **`~/.fleetest/`**
  (機械グローバル)に1本で、**リモートのディスパッチもローカル run も同じロックを取る**
  (`Sources/fleetest/LocalDispatchLock.swift`。docs/remote-runner.md §13)。守る規律6つ:
  **①置き場を `<base>` の下に戻さない**(守るのはマシンの資源 = デバイス・ポート。base が2つあると
  ロックが割れるのに取り合う相手は同じ)/ **②ローカルの取得もコマンド文字列を書かない**
  (`RemoteDispatchQueue` が作る同じシェル片を `/bin/sh -c` で撃つ)/ **③取るのは run の入口**
  (ビルドにもデバイスにも触る前。`swift build` も重い負荷なので直列化する。**dry-run は取らない**)——
  **複数機械 fan-out は配分にシナリオ一覧が要る**ので、`DeviceMachineRunner` / `ApiRunMachineFanout` は
  **①チケットを `ScenarioHost.build` より前に発行して `setenv` で確定**(発行だけでは効かない ——
  取得側は `resolveTicket(environment:)` で環境を見るので、書かないと取得時の `Date()` で
  採り直され、build 中に並んだ別 run に追い越される)**②ローカルのロックを build の前に先取りし、
  配分が確定したら local に配られたかに関わらず無条件で解放**する(build を直列化するための
  一時的な先取り)。**本取得は `DispatchPrelock` が local を含めて全順序どおり**行う/
  **④ローカルのロックの回収は pid だけ**(リモートの pgrep はローカル run を見つけられず、掛けると
  死んだロックが永久に残る。同じ機械の pid は確定できるので**リモートより強い**判定)。
  **回収は待機の毎周試す** —— 1回だけにすると、待ち始めた時点では保持者が生きているのが普通なので
  その1回はほぼ必ず空振りし、**そのあと保持者が死んでも二度と試さない**(実地 2026-09-22:
  run の親を SIGKILL した後、待っている run が上限まで待ち続けた)。
  「他人のロックは何周しても答えが変わらない」は他人のロックには正しいが、**自分のロックは
  待っている間に保持者が死ぬ = 答えが変わる**(→ maintainer-notes §42.1・§42.2)/
  **⑤ランナー機で自壊させない** —— ディスパッチ先の `run --runner local` は向こうから見れば手元の
  run なので、`RemoteShell.remoteRunCommand` が `FT_DISPATCH_LOCK_HELD='local'` を export して
  二重取得を止める(**`remoteExecCommand` には置かない** = exec はロックを取らない)/
  **⑥run-lease(台ごと)は残す** —— MCP の印と `start-device` 等は dispatch.lock を取らないので、
  台ごとの調停はあちらでしか成立しない。順序は「マシンの門 → 台の門」だが、**fan-out の
  `rejectIfLocalDevicesLeasedBeforeDispatch` だけは手前**(読み取りの先読み = どのロックも取る前に断る)。
  **`--wait-lock` が渡されていれば、この先読みも待ってから再判定する**(`WaitLockPolling` の同じ刻み。
  1マシン1 run が保証されている = 走っている run が終われば台の lease は**必ず**空くので、
  待たずに断ると連続実行の後発が待機列に並べないまま落ちる。→ maintainer-notes §42.4)
- **順番待ちは FIFO の待機列**(docs/remote-runner.md §18.9。`FTRemote.RemoteDispatchQueue`):
  `dispatch.lock` の**手前**に `~/.fleetest/dispatch.queue/<13桁epoch>~<issuer>~<group>` を置き、
  **先頭のチケットの持ち主だけが `mkdir` を撃つ**(ロックの原子性は mkdir のまま)。
  守る規律4つ: **①待たない取得も列を通す**(通さないと並んでいる人を追い越せて FIFO が壊れる。
  列を通らないのは `--force-lock` だけ)/ **②チケットの鍵は発行側が1回だけ採り
  `FT_DISPATCH_TICKET` で全機械へ運ぶ**(機械ごとに採り直すと同じ run の前後関係が機械によって
  食い違い、互いに相手の機械を待つ)/ **③失効は mtime の 30 秒**(= ポーリング間隔 × 3。
  **ここが唯一 mtime に頼る場所** = 発行側の pid はランナーから見えない。**失効しても run は
  1本も殺さない** —— 列から落ちるだけで、ロック本体には時刻判定を一切入れない)/
  **④保持者が読めないときに「実行中」と言わない**(自分の番でないだけのときは、控えが nil でも
  ロックは空いていることがある = §18.7「不明と空きを混ぜない」の同型)。
  待機は `dispatchWaiting`(NDJSON)で拡張の実行ログビューへ出し、**ログとイベントは同じ刻みの
  式を1つ通す**(数字が2箇所で食い違わない)
- **複数機械 run のロックは親が1台ずつ取る**(資源順序付け。docs/remote-runner.md §18.10。
  `FTRemote.DispatchOrder` / `Sources/fleetest/DispatchPrelock.swift`): **全員が同じ順序でしか
  取らない**ので循環待ちを作れない(検出も自己解消も要らない)。守る規律5つ:
  **①順序の鍵はランナーのハードウェア UUID**(`IOPlatformUUID`。**IP は1台に複数付き・
  ホスト名は重複と mDNS で変わる・`<base>` 配下の ID は同じ Mac に base を2つ作ると割れる**。
  採取は接続の1往復に相乗り = ssh を足さない)/ **②並べ替えは `DispatchOrder.sorted` の1箇所**
  (不明は最後尾・tie-break まで下ろして全順序にする = 非安定ソートで並びが揺れない)/
  **③印(`FT_DISPATCH_LOCK_HELD`)は真偽値でなく ssh 宛先**(環境変数は子孫へ継がれるので、
  真偽値だと別の宛先の子まで取得を飛ばして誰もロックを持たない)/ **④子は取得と解放の両方を
  スキップする**(取得だけ飛ばすと子の defer が親のロックを消し、解放だけ飛ばすと子が親を待って詰む)/
  **⑤子へ `--wait-lock` を渡さない**(待つのは親。渡すと親が待ち切った上限を子がもう一度払う)/
  **⑥local を全順序の外へ出さない**(→ maintainer-notes §42.3) —— 「手元はもう取ってあるから飛ばす」という口を作ると、
  **A が手元を握って M1Max を待ち、B が M1Max を握って手元を待つ**形が作れて①〜②の保証が消える
  (build 前の先取りは**必ず解放してから** `acquireInOrder` に入る。`DispatchPrelock` の local 分岐から
  取得を飛ばす return を足さない = `DispatchLockBeforeBuildOrderingTests` が走査で固定)。
  **取れなかった機械は飛ばす**(部分列でも順序の一貫性は保たれる)・**印が無ければ子が自分で取る**
  ので単発 run は無改造。**緑の run では1度も実行されない**ので、差し替え口に偽のランナー群を
  注入した単体と、**順序付けが無い形で確定的にデッドロックする陽性対照**を対で置く
- **リモート制御(実行プロファイルの `remoteControl`)**: ワークスペース(資材の置き場)+
  **run 前後のスクリプト**(docs/remote-runner.md §17)。**スクリプトに宣言は無い** ——
  `<workspace>/scripts/setup.sh` / `teardown.sh` が**あれば実行、無ければ何もしない**
  (名前も置き場所も固定。拡張のフォームにも入力欄を置かない = ユーザー決定)。
  **呼ぶのは `ProfileRunner.run` と `ApiRunCommand` の2箇所** —— リモートの子は
  `fleetest run --runner local` として向こうで同じコードを通るので `RemoteRunDispatcher` には
  足さない。守る規律3つ: **①setup の失敗は run を止める**(teardown の失敗は結果を変えない)/
  **②デバイスに触る前に撃つ** / **③片付けは defer だけに頼らない** —— setup の前に
  `.fleetest/hooks/<pid>.json` を置き、次の run 開始時と `fleetest hooks reap`(`remote clean` が撃つ)が死んだ pid の
  ぶんを代わりに実行する(**生存判定は pid だけ。mtime を見ない**)。**④刺さっても打ち切らない**
  (上限の根拠がこちらに無い)—— 無音が `RunHookStall.silentWarningSeconds`(60 秒)を跨ぐたびに
  警告を 1 行出して待ち続ける(出力が来れば数え直す)。
  **転送から外すのは `.fleetest-transfer-ignore`**(`FTCore.TransferIgnore`)。
  **rsync の `-F`(dir-merge)は使わない** → maintainer-notes §3.4。
  **3つの転送(run ディスパッチ・fan-out の `RemoteProjectSync`・プロジェクト外ミラー)が
  同じ走査を通る**(`rsyncArgs` の `ignore:` は既定値無し = 読み忘れはコンパイルで止まる)
