// VSCode拡張のライブ操作パネル向け常駐 CLI(fleetest api live serve)。ドライバを起動時に
// 1回だけ生成して使い回し(操作ごとのプロセス起動を避ける)、stdin から NDJSON でコマンドを
// 1行ずつ受けて逐次処理する。
//
// snapshot/tap/type/swipe/launch/terminate/install はこの serve コマンドに統合されている。
//
// プロトコル(stdin → serve、1行1コマンドの NDJSON):
//   {"cmd":"tap","ref":<Int>}                           snapshot の参照番号をタップ
//   {"cmd":"tap","x":<Double>,"y":<Double>}             座標(pt)をタップ
//   {"cmd":"type","text":<String>,"ref":<Int省略可>}     テキスト入力(ref省略時はフォーカス中の要素)
//   {"cmd":"clear","ref":<Int省略可>}                    入力欄をクリア(ref省略時はフォーカス中の要素)
//   {"cmd":"hideKeyboard"}                              フォーカス中の入力のソフトキーボードを閉じる
//                                                        (**Android のみ**。iOS は 501 で、閉じるのは pressEnter)
//   {"cmd":"swipe","direction":"up"|"down"|"left"|"right"}
//   {"cmd":"drag","fromX":..,"fromY":..,"toX":..,"toY":..,"press":<秒省略可>,"duration":<秒省略可>,
//    "maxGestureSeconds":<秒省略可>}                    **斜めのパンはこれで撃つ**(両軸を動かす)
//   {"cmd":"doubleTap","ref":<Int>} / {"cmd":"doubleTap","x":..,"y":..}
//   {"cmd":"pinch","scale":<Double>,"ref":<Int省略可>,"duration":<秒省略可>,"maxGestureSeconds":<秒省略可>}
//                                                       ref 省略 = 画面全体。scale>1 拡大 / <1 縮小
//                                                        2点間ドラッグ(座標はpt。press=押下静止時間、duration=移動時間)
//   {"cmd":"press","x":<Double>,"y":<Double>,"duration":<秒>,"maxGestureSeconds":<秒省略可>}  座標ロングプレス
//                                                       press/drag/pinch の秒数は既定 10 秒が上限。
//                                                       maxGestureSeconds でこの1回だけ最大60秒まで上げられる
//   {"cmd":"gesture","fingers":[{"points":[{"x":..,"y":..,"t":..}, ...]}, ...],
//    "maxGestureSeconds":<秒省略可>}                    **軌跡モード(ライブ操作パネルの
//                                                        Shift+ドラッグ)専用** —— マウスの軌跡を離さず
//                                                        1本のタッチとして再生する(GestureRequest と
//                                                        同じワイヤ形。検査は FTCore.TouchGesture.validate
//                                                        の1箇所。MCP の ft_gesture と共有)
//   {"cmd":"launch","bundle":<String>}                  bundle ID / パッケージ名を起動
//   {"cmd":"activate","bundle":<String>}               状態を保持したまま前面切替(未起動なら起動)
//   {"cmd":"appSwitcher"}                               アプリスイッチャー(タスク一覧)を開く
//   {"cmd":"home"}                                       ホーム画面に戻る
//   {"cmd":"back"}                                       前の画面へ戻る
//   {"cmd":"terminate"}                                 対象アプリを終了
//   {"cmd":"clearAppData","bundle":<String省略可>}       アプリは残しデータだけ消す(省略時は現在の
//                                                        セッションが指すアプリ。iOS はシミュレータ専用)
//   {"cmd":"install","path":<String>}                   パッケージファイル(iOS: .app / Android: .apk/.apks)
//                                                        からインストール
//   {"cmd":"refresh"}                                   操作は行わず観測のみ
//   {"cmd":"frame"}                                     スクリーンショットのみ取得(AXツリーは取らない)
// 壊れた行(JSON でない、cmd が無い)は stderr に1行ログして無視する(他の常駐 api コマンドと同じ
// 「安全側で無視する」方針)。**cmd は読めたが他の引数の型が違う行は無視しない** ——
// 操作は行わず、その cmd が正常なときと同じ終端イベントで答える(無応答のまま拡張の
// SERVE_REQUEST_TIMEOUT を待たせて serve ごと再起動させない): frame は
// {"kind":"frame","ok":false,"error":"<引数> must be …"} の1行だけ(actionResult は出さない)。
// それ以外は {"kind":"actionResult","ok":false,"error":"<引数> must be …"} に続けて観測イベント
// (snapshot)を出す。
//
// イベント(serve → stdout、1行1JSON。診断は stderr のみ):
//   refresh 以外のコマンドはまず
//     {"kind":"actionResult","ok":true,"error":null,"app":"<bundle ID>"|null,"bridgeStarting":<Bool>}
//     {"kind":"actionResult","ok":false,"error":"<説明>","app":"<bundle ID>"|null,"bridgeStarting":<Bool>}
//   のどちらかを出し、続けて(操作の成否を問わず)観測イベント
//     {"kind":"snapshot","ok":true,"error":null,"platform":"ios"|"android",
//      "screen":{"width":..,"height":..},"image":"<base64 JPEG>",
//      "elements":[{"ref":..,"type":"..","label":..|null,"identifier":..|null,"value":..|null,
//                    "frame":{"x":..,"y":..,"width":..,"height":..}}, ...],
//      "notes":[<String>, ...],"bridgeStarting":<Bool>}   観測そのものへの注記(鮮度警告等。
//                                 FTCore.StaleFrameDetector。無ければ空配列。elements と違い null にしない)
//     {"kind":"snapshot","ok":false,"error":"<説明>","platform":null,"screen":null,"image":null,
//      "elements":null,"notes":[],"bridgeStarting":<Bool>}
//   を出す(操作後の追加waitは無し。ブリッジの操作応答=UI整定済みのため)。
//   refresh はこの観測イベント1行だけを出す(actionResult は出さない)。
//   frame は {"kind":"frame","ok":..,"error":..,"image":"<base64 JPEG>"|null,"bridgeStarting":<Bool>}
//   の1行だけを出す(actionResult・snapshot は出さない。ライブ操作パネルの自動画面更新用)。
//   拡張側は actionResult が ok:false のとき、続く snapshot イベントは画面へ反映しない
//   (直前の表示を保持したままエラーを表示する)。
//   app は**その操作を撃った先**(セッションの向き先)。ライブ操作はセッションを前面のものへ
//   追従させるので、ホーム画面・別のアプリを触った操作もここへ来る —— 拡張はこれを見て
//   レコーディングに載せるかを決める(対象アプリ以外の操作は記録しない)。iOS のみ・
//   分からなければ null(拡張は null を従来どおり「対象アプリの操作」として扱う)。
//   bridgeStarting: **必須**。`LiveBridgeAutoStarter` が自動起動を進行中(.starting)かどうかを
//   イベントの時点で読んだ値(starter が無ければ常に false)。ok の真偽を問わず全イベントに載る
//   (annotated が noteConnectionRefused() で idle→starting へ遷移させ得るため、失敗イベントでは
//   annotated の**後**に読む=たった今始まった自動起動も true になる)。拡張はこれを見て、
//   起動中の失敗を「エラー」ではなく「接続中」の中立表示にする(自動で撃ち直しはしない)。
//   **error 文言は自動起動の進捗を運ばない** —— 従来の "(Auto-starting the XCUITest bridge. …)"
//   サフィックスは廃止し、進捗はこのフラグだけで伝える(LiveBridgeAutoStarter.suffix() 参照。
//   起動が2回連続で失敗したときの "(Bridge auto-start failed: …)" は引き続き error 文言に残る
//   =対処が要る本物のエラーのため)。
//
// 座標契約: snapshot の screen / elements[].frame はポイント座標。
//
// セッションの向き先(iOS のみ): 操作と観測の直前に、セッションを**今 前面にあるもの**へ
// 向け直す(LiveSessionFollower)。ホーム画面・アプリスイッチャー・別のアプリ・システム
// ダイアログが前面でも、画面に映っているものをそのまま触れる。Android は何もしない。
//
// 終了: stdin EOF、または SIGTERM/SIGINT(setvbuf の行バッファ化含め他の常駐 api コマンドと同じ
// 流儀)。ただしこちらは周期処理を持たないコマンド駆動のため、StopFlag+ポーリングではなく
// AsyncStream で橋渡しし SIGTERM/SIGINT は continuation.finish() で for-await を抜けさせる。
//
// --udid(iOS のみ): 指定時、DriverError.bridgeConnectionRefused を tap 等の実行時・観測
// (emitObservation)時に検知すると LiveBridgeAutoStarter がブリッジを自動起動し、進行状況は
// 全イベント共通の bridgeStarting フラグ(上記)で伝える(詳細は LiveBridgeAutoStarter.swift)。
// 自動フレーム(emitFrame)は状況の反映のみで起動はトリガーしない。serve 起動時に /status の
// protocolVersion を確認し、旧ビルドのブリッジは自動で再起動する。
// **resolve が返した宛先は udid で本人確認する**
// (FTCore.BridgeIdentityCheck。実地: 別デバイスの生きたブリッジを掴んで操作を撃ち、版差を
// 理由に止めて建て直した実害がある)。**`--port` を明示していれば**不一致は
// bridgeIdentityMismatch で断つ(利用者が決めた宛先を勝手に変えない)。**既定ポートへの
// フォールバックなら**断らない —— `BridgeDiscovery.scan` でその udid のポートへ乗り換えるか、
// 見つからなければ別の台のブリッジには触れず空きポートを充てて自動起動へ回す(でないと、
// 自動起動が想定している「ブリッジ未着手の台を既定ポートで開く」場面そのものが塞がれる)。

import ArgumentParser
import FTAndroid
import FTBridgeClient
import Foundation
import FTCore

struct ApiLiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Resident CLI for the live-control panel of the VSCode extension (serve only; see the protocol at the top of the file)",
        subcommands: [ApiLiveServe.self])
}

// MARK: - api live serve

struct ApiLiveServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Stay resident for the live-control panel and process NDJSON commands from stdin"
            + " (see the protocol at the top of ApiLiveCommand.swift; diagnostics on stderr only)")

    @Option(name: .customLong("max-width"), help: "Maximum size of the screenshot long edge in px (0 or less = original size; default 0)")
    var maxWidth: Int = 0

    @Option(help: "Simulator UDID used to auto-start the XCUITest bridge when the connection fails (iOS only; no auto-start when omitted)")
    var udid: String?

    @OptionGroup var driverOptions: DriverOptions

    // iOS は XCUIBridgeResolver 経由で makeDriver を通らないので、ここでは効かせられない
    func validate() throws { try driverOptions.rejectVersionSkewFlag(in: "api live") }

    /// `ResidentProcessGuard.startCommandWatchdog(maxSeconds:)` に渡す基準値[秒]。拡張側の
    /// SERVE_REQUEST_TIMEOUT_MS(20秒。vscode-fleetest/src/monitorLiveController.ts)より大きくする
    /// —— 通常は拡張の kill→respawn が先に効き、これは拡張が kill しない場合の最終安全弁。
    /// 秒数を指定する操作(軌跡・press/drag/pinch)は `gestureAllowanceSeconds` ぶん延ばす
    static let commandWatchdogMaxSeconds: Double = 30

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(他の常駐 api コマンドと同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "live serve")
        // 1コマンドが wedge(CPU spin 等)しても自死できる最終安全弁(commandWatchdogMaxSeconds の宣言参照)
        ResidentProcessGuard.startCommandWatchdog(
            maxSeconds: Self.commandWatchdogMaxSeconds, logLabel: "live serve")

        var (driver, port, ownAppBundleID, primaryEngine) = try await makeLiveDriver()
        let starter = makeAutoStarter(port: port)
        // **本人確認(下)も follower と同じ値を使う**(独立に導出すると判定用と実際の駆動用が
        // 食い違う恐れがある。実機かは udid の形から決まるので一度だけ解決する)
        let physical = udid.flatMap { SimulatorCatalog.isPhysical(udid: $0) } ?? false
        // セッションを「今 前面にあるもの」へ追従させる(LiveSessionFollower)。**iOS だけ**の補正で、
        // Android は木がアクティブウィンドウ・タップが画面座標なので何もしなくても画面に追従する
        let follower = driverOptions.resolvedPlatform == "ios"
            ? LiveSessionFollower(udid: udid, physical: physical, log: { logStderr($0) }) : nil
        if let starter {
            Task { await starter.checkAndRestartIfStale() }
        }
        // **台の印(LiveDeviceLease)を起動直後から立てる**(実地 B5)。何も撃たないまま
        // 他プロセスがこの台を止められる隙を作らないため、最初のコマンドを待たずに書く
        let deviceLease = LiveDeviceLease.make(
            platform: driverOptions.resolvedPlatform, udid: udid,
            explicitAndroidSerial: driverOptions.serial, log: { logStderr($0) })
        deviceLease?.refresh()
        // serve は1プロセスが1台を見続けるので、MCP の engineKey 付き辞書と違い記録は1つで足りる
        let staleFrameTracker = LiveStaleFrameTracker()
        let screenMemo = LiveScreenMemo()

        let (lines, continuation) = AsyncStream<String>.makeStream(of: String.self)
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                continuation.yield(line)
            }
            continuation.finish()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "live serve")
        }
        reader.name = "fleetest-api-live-serve-stdin"
        reader.start()

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "fleetest-api-live-serve-signal")
        // ループを抜けるまでシグナルソースを保持する(解放されるとハンドラが外れる)
        let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler {
                continuation.finish()
                ResidentProcessGuard.scheduleForcedExit(logLabel: "live serve")
            }
            source.resume()
            return source
        }
        defer { for source in signalSources { source.cancel() } }

        for await line in lines {
            // JSON でない・cmd が無い(型も含む)行だけをここで無視する。cmd さえ読めれば
            // ApiLiveServeCommand の側で他の引数の型違いを decodeError として持ち帰り、
            // handle が actionResult(ok:false)で答える(黙って無応答のまま拡張の
            // SERVE_REQUEST_TIMEOUT を待たせない)
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cmd = object["cmd"] as? String else {
                logStderr("Ignored a line in an unknown format: \(line)")
                continue
            }
            let command = ApiLiveServeCommand(cmd: cmd, raw: object)
            // 軌跡・press/drag/pinch の duration は利用者が指定した時間どおりに再生する(縮めない)
            // ので、その再生時間ぶん watchdog を延ばす(gestureAllowanceSeconds 参照)
            ResidentProcessGuard.noteCommandStart(allowanceSeconds: command.gestureAllowanceSeconds)
            // 自動起動が成功した直後は宛先を引き直す(実機 LAN: 起動前の loopback から告知アドレスへ。
            // usb: host はループバックのままだが establish が新たに token を記録している ——
            // host だけで判定すると usb は再取得されず、起動前の token 無し driver を握ったままになる)
            if let starter, await starter.takeStarted(), let repoRoot = try? RepoRoot.find() {
                let endpoint = BridgeEndpoint.load(port: port, repoRoot: repoRoot)
                driver = BridgeClient(endpoint: endpoint)
                // **LiveBridgeAutoStarter は XCUITest しか建てない**(旧ビルド再起動・接続拒否からの
                // 起動、どちらも launchBridge が xcodebuild で建てる)ので、以後の期待エンジンも固定
                primaryEngine = "xcuitest"
                logStderr("switched the driver to \(endpoint.host):\(port) (announced by the runner)")
            }
            // **port の本人確認(udid + エンジン)を毎コマンド撃つ**(maintainer-notes §51.2・§51.10 と同型の穴):
            // makeLiveDriver は起動時に1回組むきりで、フリートが run のたびにブリッジを
            // 建て直すと port が別デバイス、あるいは**同じデバイスの別エンジン**へ移り得る ——
            // hybrid なら home/appSwitcher/drag/座標 press/gesture/pinch(fallback 経由)が、
            // 非 hybrid ならすべての呼び出しが黙って別物(別デバイス、または in-app ⇄ xcuitest で
            // ref 体系・サポート操作が別)へ届く。primaryEngine(composeDriver が決める。
            // hybrid/genuine xcuitest は "xcuitest"、in-app 単独は "inapp")を期待値にするので、
            // in-app 単独の構成を xcuitest 期待で誤検知しない。
            // **frame(自動更新)には掛けない**(継続的に飛ぶので絶え間ない probe になる。
            // ライブ操作は人の操作1つに1回なのでコマンドごとの probe は許容できる)。
            // 判定は MCP(fleetest-mcp)と同じ `FTBridgeClient.HybridFallbackIdentity`
            // (`FTCore.BridgeIdentityCheck`)の1箇所。**不明は「変わった」に倒さない**
            // **`expectedEngine` という別名で unwrap する**(`if let primaryEngine` にすると、
            // ブロック内の `primaryEngine` が外側の `var`(4行下の代入対象)を隠して
            // 「let への代入」でコンパイルエラーになる)
            if command.cmd != "frame", driverOptions.resolvedPlatform == "ios", let udid,
               let expectedEngine = primaryEngine,
               let repoRoot = try? RepoRoot.find() {
                let drift = await HybridFallbackIdentity.drifted(
                    port: port, expectedUDID: udid, expectedEngine: expectedEngine, repoRoot: repoRoot)
                switch Self.liveDriftOutcome(drift: drift, port: port, expectedUDID: udid) {
                case .unchanged:
                    break
                case .rebuild:
                    // **建て直しは「switched the driver」と同じ形**(再解決してから組み直す)。
                    // composeDriver は in-app 側の本人確認もその内側でやり直す。**ポートが動いていたら
                    // 追従しない** —— starter/deviceLease は元の port を見続けるので、ここで
                    // 乗り換えると自動起動・台の印との整合が崩れる(乗り換えは makeLiveDriver の
                    // 起動時ロジックの役目で、ここでは再現しない)
                    let resolution = await XCUIBridgeResolver.resolve(
                        preferred: port, repoRoot: repoRoot, autoStart: false,
                        logger: { message in ConsoleOut.err("[live serve] " + message) })
                    if resolution.endpoint.port == port,
                       let rebuilt = try? await composeDriver(
                           resolution: resolution, physical: physical, repoRoot: repoRoot) {
                        (driver, port, ownAppBundleID, primaryEngine) = rebuilt
                        logStderr("port \(port) no longer matched \(udid) (expected the \(expectedEngine)"
                                  + " engine) — rebuilt the driver")
                    } else {
                        logStderr("port \(port) no longer matches \(udid) as the \(expectedEngine) engine, but a"
                                  + " fresh resolution could not be composed for it yet — continuing with the"
                                  + " previous driver")
                    }
                case .refuse(let message):
                    // **同じポートで作り直さない**: 別の実体が答えている形なので、建て直すと乗り換えた
                    // まま気付かず操作を撃ち続ける。このコマンドは撃たず、driver/port/primaryEngine を
                    // 変えないので次のコマンドでも同じ判定・同じ拒否を繰り返す(黙って固定されない)
                    logStderr(message)
                    let starting = await bridgeStartingFlag(starter)
                    emitLine(ApiLiveActionResultEvent(ok: false, error: message, app: follower?.sessionTarget,
                                                      bridgeStarting: starting))
                    await follower?.follow(driver: driver)
                    await emitObservation(driver: driver, starter: starter, follower: follower, port: port,
                                          staleFrameTracker: staleFrameTracker, screenMemo: screenMemo)
                    ResidentProcessGuard.noteCommandEnd()
                    continue
                }
            }
            await handle(command: command, driver: driver, starter: starter, follower: follower,
                        ownAppBundleID: ownAppBundleID, deviceLease: deviceLease, port: port,
                        staleFrameTracker: staleFrameTracker, screenMemo: screenMemo)
            ResidentProcessGuard.noteCommandEnd()
        }
        // stdin EOF / シグナルでループを抜けた。自分の印を残すと、使っていない台を他プロセスが
        // 「対話セッションが使用中」として避け続ける(MCPServer.run の後始末と同じ理由)
        deviceLease?.release()
    }

    /// live のドライバ構成。**自アプリだけ in-app を主にする**(ユーザー決定 2026-09-22) ——
    /// WKWebView の中身を DOM で読めるのは in-app だけで、レコーディングはそれに依る。
    /// それ以外(別アプリ・SpringBoard)と、in-app が原理的に実行できない操作
    /// (home / appSwitcher / 座標 drag・press)は XCUITest が受け持つ。
    /// 仕分けは `HybridFallbackDriver` と `WebViewDelegatingDriver` が持っている既存の規律を
    /// そのまま使う(MCP の ft_* と同じ構成。二つ目の実装を書かない)。
    ///
    /// in-app が居ない(指定ポートが XCUITest・Android)ときは従来どおり単独で使う。
    /// 戻り値のポートは以後の自動起動・再起動が同じ宛先を見るために返す。3つ目の戻り値は
    /// hybrid のとき in-app が住んでいる own app の bundleID(launchGuard が own app への
    /// launch/activate を素通しするのに使う。hybrid でなければ nil)
    ///
    /// **resolve が返した宛先は udid で本人確認する**(FTCore.BridgeIdentityCheck。実地 L1:
    /// 既定ポートに別デバイスの生きたブリッジが居るのを見逃し、操作を撃ち・版差を理由に止めて
    /// 建て直した)。**`--port` を明示したか既定へのフォールバックかで扱いを分ける**
    /// (`BridgeDiscovery` の既存の切り分け「port: を明示した呼び出しでは探索しない」の裏返し。
    /// `driverOptions.port == nil` = 利用者は宛先を決めていない):
    /// ①明示 かつ 不一致 → 断る(利用者が決めた宛先を勝手に変えない)/
    /// ②フォールバック かつ 不一致 → `BridgeDiscovery.scan` からその udid のポートを探し、
    /// 見つかれば乗り換える / ③見つからなければ**別の台のブリッジは掴んだままにしない** ——
    /// 空きポートを充てて「まだ居ない」の形(接続拒否)に落とし、自動起動
    /// (LiveBridgeAutoStarter)に委ねる。ここが無いと、自動起動が想定している
    /// まさにその場面(ブリッジ未着手の台を既定ポートで開く)が塞がれる
    /// **4つ目の戻り値**(maintainer-notes §51.10): `port` の期待エンジン(composeDriver 参照)。**Android と、
    /// 台がまだ無いプレースホルダ(自動起動待ち)は nil** —— どちらも「今 probe してよい
    /// エンジンの期待」が無い(Android は engine の概念が無く、プレースホルダは
    /// 何も応答しない = 自動起動の成功を「switched the driver」が拾ってから初めて分かる)。
    /// run() の毎コマンド確認は nil のときは何もしない
    private func makeLiveDriver() async throws -> (AppDriver, UInt16, String?, String?) {
        guard driverOptions.resolvedPlatform == "ios" else {
            return (try await driverOptions.makeDriver(), driverOptions.resolvedPort, nil, nil)
        }
        let repoRoot = try? RepoRoot.find()
        // **autoStart:false**(= 走査までで止める)。serve は常駐で、拡張は応答が無いと
        // kill→respawn するため、起動時に build-for-testing(分単位)でブロックしてはいけない。
        // hybrid は in-app と XCUITest を両方張るので走査だけで必ず見つかる。
        // 見つからないのは engine=inapp 単独のときで、そのときは理由を stderr に出して素通しする
        let resolution = await XCUIBridgeResolver.resolve(
            preferred: driverOptions.resolvedPort, repoRoot: repoRoot, autoStart: false,
            logger: { message in
                ConsoleOut.err("[live serve] " + message)
            })
        let physical = udid.flatMap { SimulatorCatalog.isPhysical(udid: $0) } ?? false
        guard let udid else {
            return try await composeDriver(resolution: resolution, physical: physical, repoRoot: repoRoot)
        }
        // resolve は preferred ポートを疎通・engine だけで採る(別デバイスでも疎通すれば
        // そのまま返す)。ここで本人確認してから使う(以後の checkAndRestartIfStale も
        // この確認を経た宛先にしか触れない)
        let isInAppOnly = resolution.inApp?.endpoint.port == resolution.endpoint.port
        let identity = await Self.portIdentity(
            endpoint: resolution.endpoint, requestedUDID: udid, physical: physical, isInApp: isInAppOnly)
        let mismatch: String
        switch identity {
        case .mine:
            return try await composeDriver(resolution: resolution, physical: physical, repoRoot: repoRoot)
        case .mismatch(let detail):
            mismatch = detail
        case .silent:
            // **応答が無いことを「この台のブリッジ」と読まない**(§18.7「不明と空きを混ぜない」の同型)。
            // ただし **busy は正常**(XCUITest は駆動中 /status に答えない)なので、
            // `/status` の代わりに**プロセスの実体**で占有者を見る —— **肯定的に別のデバイスと
            // 読めたときだけ**掴むのをやめる。決めつけて進むと、この後の自動起動がそのポートへ
            // 自分のブリッジを立て、占有者の生きたランナーを残骸として殺す
            // (実地 2026-09-23: ブリッジを失った実機2台が既定ポート 8123 で殺し合った)。
            // 利用者が --port で決めた宛先は従来どおり進む(指定を勝手に変えない)。
            // **占有者を読めるのはループバックの宛先だけ** —— 実機の LAN bind は向こうの機械の
            // ポートなので、こちらの lsof が同じ番号で見つけるのは無関係なプロセス。
            // 読めない相手を根拠に宛先を変えない(§18.7「不明と空きを混ぜない」の同型)
            guard driverOptions.port == nil, resolution.endpoint.isLoopback,
                  PortHolder.isHeldByAnotherDevice(port: resolution.endpoint.port, udid: udid) else {
                return try await composeDriver(resolution: resolution, physical: physical,
                                               repoRoot: repoRoot)
            }
            mismatch = "port \(resolution.endpoint.port) did not answer /status and is held by"
                + " another device's process, so it is not the bridge of \(udid)"
        }
        guard driverOptions.port == nil else {
            // 利用者が --port で決めた宛先。勝手に変えず断る
            throw DriverError.bridgeIdentityMismatch(mismatch)
        }
        // 既定ポートへのフォールバック。まず udid が生きているポートを探し、見つかれば乗り換える
        let found = await BridgeDiscovery.scan(excluding: driverOptions.resolvedPort, repoRoot: repoRoot)
        if let match = found.first(where: { $0.udid == udid }) {
            logStderr("\(mismatch) — switching to port \(match.port) for \(udid)")
            let rerouted = await XCUIBridgeResolver.resolve(
                preferred: match.port, repoRoot: repoRoot, autoStart: false,
                logger: { message in ConsoleOut.err("[live serve] " + message) })
            return try await composeDriver(resolution: rerouted, physical: physical, repoRoot: repoRoot)
        }
        // この台のブリッジはまだ無い。既定ポートは別デバイスが使っているので**触らず**、
        // 空きポートへ自動起動を回す(そのポートは何も応答しないので、最初の操作が
        // bridgeConnectionRefused を撃ち、既存の接続拒否経路がそのまま面倒を見る)
        logStderr("\(mismatch) — no existing bridge for \(udid); auto-starting on a free port instead")
        guard let repoRoot else { throw DriverError.bridgeIdentityMismatch(mismatch) }
        // **採番は `ProvisionLock` の内側で撃つ**(同時に走る供給・自動起動と同じ空きポートを
        // 選ばない = `ProvisionLockStartupPathsSyncTests` が集合を固定する経路の1つ)。
        // **これは予約ではない** —— ここではまだ `.pid` を書けないので、起動までに埋まったら
        // `LiveBridgeAutoStarter` が占有者を名指しして諦める(ポートを固定で持つため逃がせない)
        let provisionLock = try? ProvisionLock(stateDir: repoRoot.appendingPathComponent(".fleetest"))
        await provisionLock?.acquire()
        let picked = XCUIBridgeResolver.freePort(
            repoRoot: repoRoot, occupied: Set(found.map(\.port)).union([driverOptions.resolvedPort]))
        provisionLock?.release()
        guard let freePort = picked else {
            throw DriverError.bridgeIdentityMismatch(mismatch)
        }
        let placeholder = BridgeClient(endpoint: BridgeEndpoint.load(port: freePort, repoRoot: repoRoot))
        return (placeholder, freePort, nil, nil)
    }

    /// resolve(または乗り換え後の resolve)の結果から実際に使うドライバを組み立てる。
    /// hybrid の in-app 側(別ポート)はここで初めて本人確認する——xcuitest 側だけでは検分できない。
    /// **4つ目の戻り値**は、以後の毎コマンドの本人確認(run() の drift チェック・maintainer-notes §51.10)が
    /// `port` へ probe を撃つときの期待エンジン —— hybrid/genuine xcuitest は `"xcuitest"`、
    /// XCUITest が見つからず in-app 単独に落ちたときだけ `"inapp"`(`port` がそのまま
    /// in-app ポートを指すため)。ここを固定にすると in-app 単独の構成を xcuitest 期待で
    /// probe してしまい、毎コマンド誤検知で作り直しを繰り返す
    private func composeDriver(
        resolution: XCUIBridgeResolver.Resolution, physical: Bool, repoRoot: URL?
    ) async throws -> (AppDriver, UInt16, String?, String?) {
        let xcui = BridgeClient(endpoint: resolution.endpoint)
        // in-app が居て、かつ振り替え先(XCUITest)が別に取れているときだけ組む。
        // 同じ宛先しか無い = XCUITest が見つからなかった場合は、in-app 単独では home も
        // appSwitcher も撃てないので XCUITest 側(= そのまま)に寄せる
        guard let inApp = resolution.inApp, inApp.endpoint.port != resolution.endpoint.port,
              let repoRoot, let udid else {
            // **in-app 単独の判定は「inApp があり、かつそのポートが resolution.endpoint と同じ」
            // だけ**(makeLiveDriver の isInAppOnly と同じ式)。inApp はあるがポートが違う
            // (hybrid になり得たのに repoRoot/udid が無くて諦めた)回は resolution.endpoint が
            // xcuitest 側なので、ここで inApp の有無だけで判定すると誤る
            let isInAppOnly = resolution.inApp.map { $0.endpoint.port == resolution.endpoint.port } ?? false
            return (xcui, resolution.endpoint.port, nil, isInAppOnly ? "inapp" : "xcuitest")
        }
        // hybrid の in-app 側は別ポート(=別ブリッジ)なので、呼び出し元の確認はこちらを検分していない。
        // 無応答(.silent)は従来どおり素通し —— in-app は背面へ回ると答えないので、ここで断ると
        // 通常の遷移で serve が開けなくなる
        if case .mismatch(let detail) = await Self.portIdentity(
            endpoint: inApp.endpoint, requestedUDID: udid, physical: physical, isInApp: true) {
            throw DriverError.bridgeIdentityMismatch(detail)
        }
        let inAppDriver = InAppDriver(repoRoot: repoRoot, udid: udid, port: inApp.endpoint.port)
        // attach は**同じインスタンス**を委譲とフォールバックの両方に使う(MCP と同じ理由:
        // activate/attached 状態を1本にしないと余計な activate が挟まる)
        let attach = AppAttachDriver(port: resolution.endpoint.port, host: resolution.endpoint.host,
                                     bundleID: inApp.bundleID, physicalUDID: physical ? udid : nil)
        ConsoleOut.err("[live serve] own app \(inApp.bundleID) is driven in-app (DOM);"
                       + " other apps and home/appSwitcher go through XCUITest (port \(resolution.endpoint.port))")
        // **合成は HybridDriverComposition の1箇所**(MCP の ft_* と同じ形。二つ目の実装を書かない)
        let driver = HybridDriverComposition.inAppFirst(
            inApp: inAppDriver, attach: attach, foreignApp: xcui, bundleID: inApp.bundleID)
        // 以後の自動起動・再起動が見るのは **XCUITest 側**(in-app は dylib 注入で建て直せない)。
        // fallback(xcuitest)側の期待エンジンは常に "xcuitest"(MCP の hybridFallbackPorts と同じ)
        return (driver, resolution.endpoint.port, inApp.bundleID, "xcuitest")
    }

    /// 毎コマンドの本人確認(`HybridFallbackIdentity.drifted` の3値)から、この1コマンドを
    /// どう扱うかを決める。**走査から切り離した純粋関数**(MCP の `primaryEngineOutcome` と同じ
    /// 理由・テスト用): 実ブリッジ無しで「差し替える/断る/何もしない」の判定を固定できる。
    /// `sameDeviceEngineChanged` は同じ台のブリッジがエンジンを変えただけなので差し替えて続ける。
    /// `differentDevice` は別の実体なので、同じポートへ作り直すと乗り換えたまま気付かず操作を
    /// 撃ち続ける —— 断る
    enum LiveDriftOutcome: Equatable {
        case unchanged, rebuild, refuse(String)
    }

    static func liveDriftOutcome(
        drift: BridgeIdentityCheck.HybridFallbackDrift, port: UInt16, expectedUDID: String
    ) -> LiveDriftOutcome {
        switch drift {
        case .none: return .unchanged
        case .sameDeviceEngineChanged: return .rebuild
        case .differentDevice: return .refuse(differentDeviceMessage(port: port, expectedUDID: expectedUDID))
        }
    }

    /// **人間向け**(拡張のライブ操作パネルを見ている人が読む。MCP のエージェント向け文言
    /// `MCPServer.differentDeviceRefusal` をそのまま流用しない)
    static func differentDeviceMessage(port: UInt16, expectedUDID: String) -> String {
        "port \(port) now serves a different device than \(expectedUDID) — this command was not sent."
            + " Reopen live control for this device (or repoint --port/--udid) to continue."
    }

    /// endpoint が本当に `requestedUDID` の台か(判定は run 側4経路と同じ
    /// FTCore.BridgeIdentityCheck の1箇所。二つ目の実装を書かない)。
    /// **throw しない** —— 不一致をどう扱うか(断るか・乗り換えるか)は呼び出し元が
    /// `--port` の明示有無で決めるため、ここは事実だけを返す。
    /// **「応答しない」は第3の値**(`.silent`)にする —— nil(= 一致)に畳むと、待受している
    /// 他デバイスのブリッジを自分の宛先として掴み、自動起動がその占有者を残骸として殺す
    enum PortIdentity: Equatable {
        /// 応答し、この台のブリッジだった
        case mine
        /// 応答したが別の台だった(detail は利用者向けの説明)
        case mismatch(String)
        /// 応答しない(不在か、駆動中で答えられない)。どちらかは呼び手が
        /// `PortHolder.isHeldByAnotherDevice`(プロセスの実体)で分ける
        case silent
    }

    private static func portIdentity(
        endpoint: BridgeEndpoint, requestedUDID: String, physical: Bool, isInApp: Bool
    ) async -> PortIdentity {
        guard let reported = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: 3)
            .status(timeout: 3) else { return .silent }
        let status = BridgeDiscovery.statusForIdentityCheck(
            reported, port: endpoint.port, repoRoot: try? RepoRoot.find())
        let expected = BridgeIdentityCheck.Expected(
            port: endpoint.port, udid: requestedUDID, physical: physical,
            engine: isInApp ? "inapp" : "xcuitest")
        // **対処は run のレーンと違う** —— ここで直すのは宛先の指定で、レーンの建て直しではない
        if case .mismatch(let detail) = BridgeIdentityCheck.verdict(
            expected: expected, status: status,
            remedy: "Point --port at this device's bridge, or omit --port and let the tools find it"
                + " (they start one when the device has none).") {
            return .mismatch(detail)
        }
        return .mine
    }

    /// platform=ios かつ --udid 指定時のみ自動起動を有効化する。RepoRoot.find() の失敗は
    /// serve 自体を止めず自動起動なしで続行する(--udid 未指定時と同じ扱いに落とす)。
    /// **physical は construction 時に1回だけ解決する**(SimulatorCatalog.isPhysical(udid:)。
    /// 判別できなければシミュレータ扱いに倒す = 従来の既定 false と同じで退行しない)
    private func makeAutoStarter(port: UInt16) -> LiveBridgeAutoStarter? {
        guard driverOptions.resolvedPlatform == "ios", let udid else { return nil }
        do {
            let repoRoot = try RepoRoot.find()
            let physical = SimulatorCatalog.isPhysical(udid: udid) ?? false
            // 実機の到達手段は devicectl の transportType で決める(USB = iproxy / LAN = 告知アドレス)。
            // 一覧に無ければ LAN 側へ倒す(USB 側へ倒すと iproxy を待って必ず失敗する)
            var wired = false
            if physical {
                let info = (try? IOSPhysicalDeviceCatalog.devices())?
                    .first { $0.udid == udid || $0.deviceCtlIdentifier == udid }
                wired = info?.transport == "wired"
                if info == nil { logStderr("transport of \(udid) is unknown to devicectl — assuming LAN") }
            }
            return LiveBridgeAutoStarter(repoRoot: repoRoot, udid: udid, port: port,
                                         physical: physical, wired: wired)
        } catch {
            logStderr("Repository root not found — disabling bridge auto-start: " +
                error.localizedDescription)
            return nil
        }
    }

    /// 1コマンドを処理する: refresh 以外はまずアクションを実行して actionResult を出し、
    /// 続けて(操作の成否を問わず)観測イベントを出す。refresh は観測イベントのみ
    private func handle(
        command: ApiLiveServeCommand, driver: AppDriver, starter: LiveBridgeAutoStarter?,
        follower: LiveSessionFollower?, ownAppBundleID: String?, deviceLease: LiveDeviceLease?,
        port: UInt16, staleFrameTracker: LiveStaleFrameTracker, screenMemo: LiveScreenMemo
    ) async {
        // **コマンドが通るたびに台の印を上書きする**(MCPServer.call の markDeviceInUse と同じ粒度。
        // 型違い・未知の cmd で終わる回も含めて全コマンドで更新する——駆動している事実に変わりはない)
        deviceLease?.refresh()
        if let decodeError = command.decodeError {
            // cmd は読めたが他の引数の型が違う行。JSON でない/cmd が無い(黙殺)とは分け、
            // 操作は行わず、その cmd が正常なときと同じ終端イベントで答える —— 拡張は
            // actionResult/frame の後に来るイベント(snapshot または frame そのもの)で初めて
            // リクエストを解決するため、そこを省くと20秒の SERVE_REQUEST_TIMEOUT で serve ごと
            // 再起動される(実地: launch/pinch/tap の型違い行がこれで無応答のまま再起動を誘発した)。
            // frame は frame イベント1行だけ(actionResult は出さない=通常の frame 経路と同形)。
            // それ以外は actionResult(ok:false) に続けて観測イベントを出す(通常経路と同形)
            let starting = await bridgeStartingFlag(starter)
            if command.cmd == "frame" {
                emitLine(ApiLiveFrameEvent(ok: false, error: decodeError, image: nil, bridgeStarting: starting))
                return
            }
            emitLine(ApiLiveActionResultEvent(ok: false, error: decodeError, app: follower?.sessionTarget,
                                              bridgeStarting: starting))
            await follower?.follow(driver: driver)
            await emitObservation(driver: driver, starter: starter, follower: follower, port: port,
                                  staleFrameTracker: staleFrameTracker, screenMemo: screenMemo)
            return
        }
        if command.cmd == "frame" {
            // 自動画面更新は `/screenshot`(XCUIScreen = 画面そのもの)だけなのでセッションに依らない。
            // ここで追従させると、利用者が何もしていない間もセッションを動かすことになる
            await emitFrame(driver: driver, starter: starter, port: port)
            return
        }
        if command.cmd != "refresh" {
            do {
                try await perform(command: command, driver: driver, follower: follower,
                                  ownAppBundleID: ownAppBundleID, screenMemo: screenMemo)
                emitLine(ApiLiveActionResultEvent(ok: true, error: nil, app: follower?.sessionTarget,
                                                  bridgeStarting: await bridgeStartingFlag(starter)))
            } catch {
                let message = await annotated(error, starter: starter, triggering: true, port: port)
                // **annotated の後で読む**: noteConnectionRefused() が idle→starting へ遷移させ得るため
                emitLine(ApiLiveActionResultEvent(ok: false, error: message, app: follower?.sessionTarget,
                                                  bridgeStarting: await bridgeStartingFlag(starter)))
            }
        }
        // **観測の直前にもう一度追従させる**: 直前の操作で前面が変わっている(ホームへ戻った・
        // 別のアプリが出た)ことがあり、古いセッションのまま撮ると画面ではなく最後の状態が載る
        await follower?.follow(driver: driver)
        await emitObservation(driver: driver, starter: starter, follower: follower, port: port,
                              staleFrameTracker: staleFrameTracker, screenMemo: screenMemo)
    }

    /// 各イベントの `bridgeStarting` フィールドの唯一の算出元(starter が無ければ false)。
    /// **失敗イベントでは必ず annotated(...) の後に呼ぶこと** —— annotated が
    /// noteConnectionRefused() 経由で starter を idle→starting へ遷移させ得るため、先に読むと
    /// 遷移前の値(false)を拡張へ渡し、たった今始まった自動起動を「していない」と報告する
    private func bridgeStartingFlag(_ starter: LiveBridgeAutoStarter?) async -> Bool {
        await starter?.isStarting ?? false
    }

    /// error が DriverError.bridgeConnectionRefused のときだけ starter のサフィックスを連結する
    /// (bridgeUnreachable やタイムアウトでは連結しない=生きているブリッジとの二重起動を防ぐ)。
    /// triggering: true なら noteConnectionRefused(起動トリガーあり)、false なら
    /// statusSuffix(起動トリガーなし。emitFrame は受動的観測のため)。
    ///
    /// **triggering の区別が効くのは bridgeConnectionRefused と bridgeUnreachable の2つ**。
    /// 以下の1つは起動トリガーを持たない事実の注記なので、emitFrame(triggering:false)からも
    /// 同じだけ付く:
    /// - `DriverError.isNoReadableWindow` = Android の一時的な a11y 根欠落(422)。放置で自然回復する
    ///
    /// `DriverError.bridgeUnreachable`(iOS xcuitest のみ)は `BridgeUnreachableGuidance.decide` の
    /// 1箇所で starter の状態も加味して出口を決める(純粋関数 = デバイス無しでテストできる)。
    /// **starter が starting/failed の間は probe の中身を見ない** ——
    /// 実地: 実機の起動待ち中に probe が transportFailed を返し、「起動中です(自然に直ります)」の
    /// 直後に「自然には直りません: bridge up してください」という矛盾した案内を出した。
    /// **失敗パスでだけ撃つ**(annotated は catch 節からしか呼ばれない = 成功パスへの往復は増えない)
    private func annotated(
        _ error: Error, starter: LiveBridgeAutoStarter?, triggering: Bool, port: UInt16
    ) async -> String {
        var message = error.localizedDescription
        if let starter, case DriverError.bridgeConnectionRefused = error {
            message += triggering ? await starter.noteConnectionRefused() : await starter.statusSuffix()
            return message
        }
        if DriverError.isNoReadableWindow(error) {
            return message + Self.noReadableWindowHint
        }
        if SessionRecoveryDriver.isAccessibilityTemporarilyDown(error) {
            return message + Self.accessibilityOutageHint
        }
        if case DriverError.bridgeUnreachable(let context, _) = error, context.engine == .iosXCUITest {
            let probe = await BridgeDiscovery.probeStatus(port: port, repoRoot: try? RepoRoot.find())
            let starterIsIdle = await starter?.isIdle ?? true
            switch BridgeUnreachableGuidance.decide(
                probe: probe, hasStarter: starter != nil, starterIsIdle: starterIsIdle,
                triggering: triggering) {
            case .useStarterSuffix:
                message += await starter?.statusSuffix() ?? Self.bridgeUnreachableHint(probe: probe)
            case .triggerStarter:
                message += await starter?.noteConnectionRefused() ?? Self.bridgeUnreachableHint(probe: probe)
            case .probeHint:
                message += Self.bridgeUnreachableHint(probe: probe)
            }
        }
        return message
    }

    /// starter の有無・状態と probe の結果から、bridgeUnreachable の失敗にどの文言を足すか決める
    /// (純粋関数。BridgeUnreachableGuidanceTests がデバイス無しで全分岐を固定する)。
    enum BridgeUnreachableGuidance: Equatable {
        /// starter が非 idle(starting/failed)—— probe の中身を問わず starter の状態を使う
        /// (probe が transportFailed でも、進行中の自動起動と矛盾する「自然には直らない」を出さない)
        case useStarterSuffix
        /// starter が idle・能動経路(triggering)・probe がブリッジ消失(transportFailed/notBound)
        /// —— bridgeConnectionRefused と同じ状況なので同じ起動トリガーへ倒す
        case triggerStarter
        /// 上記のどちらでもない(starter が無い/busy/応答あり/受動経路) —— 従来どおり probe のヒント
        case probeHint

        static func decide(
            probe: BridgeDiscovery.StatusProbe, hasStarter: Bool, starterIsIdle: Bool, triggering: Bool
        ) -> Self {
            guard hasStarter else { return .probeHint }
            guard starterIsIdle else { return .useStarterSuffix }
            guard triggering, probe == .transportFailed || probe == .notBound else { return .probeHint }
            return .triggerStarter
        }
    }

    /// Android の「アクティブウィンドウの a11y 根が無い」422(`DriverError.isNoReadableWindow`)の
    /// 人間向けヒント。事実は MCP の `noReadableWindowHint`(MCPServer+Dispatch.swift)と同じ
    /// (一時的なデバイス側の状態・アプリやツールの不具合ではない・13〜37秒で自然回復・前面へ
    /// 戻すと早い)——判定は共有し、文言だけライブ操作の利用者向けに書き直す(ft_navigate/ft_launch
    /// という MCP 専用の呼び方はしない)
    static let noReadableWindowHint =
        " This is a temporary device-side condition, not an app or tool problem — it clears on its"
        + " own (usually within 13-37s). Doing the exact same thing again immediately will most"
        + " likely fail the same way, so wait a few seconds first. Bringing the app back to the"
        + " foreground (send it Home, then reopen it) tends to clear it faster."

    /// XCTest の a11y サーバが一時的に落ちている(500 + kAXErrorAPIDisabled)ときの人間向けヒント。
    /// 判定は `SessionRecoveryDriver.isAccessibilityTemporarilyDown`(run の再キューと同じ1箇所)で、
    /// 文言だけライブ操作の利用者向けに持つ。読みは既に数秒ぶん撃ち直した後なので、
    /// できるのは「少し待つ」だけ —— これが無いと生の XCTest のエラーだけが画面に出る
    static let accessibilityOutageHint =
        " The device's accessibility server is momentarily down — an environment fault, not a"
        + " problem with the app or this tool. The read was already retried for a few seconds."
        + " Wait a moment and try again; if it keeps happening, restart the simulator/device."

    /// `BridgeDiscovery.probeStatus` の結果ごとの文言(純粋関数)。**固まり(transportFailed)と
    /// busy(timedOut)で対処が逆になる**のが要点 —— 固まりは建て直しが要り、busy は待てば直る。
    /// この2つを混ぜて「待て」と言い続けたのが過去のバグ(docs/maintainer-notes.md §44.1)
    static func bridgeUnreachableHint(probe: BridgeDiscovery.StatusProbe) -> String {
        switch probe {
        case .transportFailed:
            return " The device stopped responding, and the connection dropped almost immediately"
                + " rather than timing out — the bridge process itself is gone; only its transport is"
                + " still holding the port (on a physical device this typically happens when the"
                + " screen locks, or it leaves USB/Wi-Fi range). This will not recover on its own:"
                + " run `fleetest bridge up` for this device, then try again."
        case .timedOut:
            return " The device is still connected and busy (for example, waiting for the screen to"
                + " settle can take tens of seconds) — this is not a dropped connection. Wait a"
                + " moment and try again."
        case .notBound:
            return " Nothing is listening on this device's bridge port anymore. Run"
                + " `fleetest bridge up` for this device, then try again."
        case .answered:
            return " The bridge answered just now — the earlier failure looks transient. Try again."
        }
    }

    /// ref から要素を引く(doubleTap / pinch が対象の座標・identifier を採るため)。
    /// **snapshot を撮り直す**: ref は直近スナップショット基準なので、ここで採り直しても同じ番号を指す
    private static func element(ref: Int, driver: AppDriver) async throws -> ElementInfo {
        let snapshot = try await driver.snapshot()
        guard let element = snapshot.elements.first(where: { $0.ref == ref }) else {
            throw ServeCommandError.invalidArguments(
                "unknown reference number [\(ref)]. Take a snapshot first")
        }
        return element
    }

    /// **撃つ前にセッションを前面へ追従させる**コマンド(画面を触る操作)。セッションそのものを
    /// 動かすコマンド(launch / activate / terminate / clearAppData / install)は通さない ——
    /// あちらは対象のアプリを引数で名指ししており、追従させると自分で決めた向き先を上書きする
    private static func followsFrontmost(_ cmd: String) -> Bool {
        ["tap", "type", "clear", "hideKeyboard", "swipe", "drag", "doubleTap", "pinch", "press",
         "gesture", "back", "appSwitcher", "home"].contains(cmd)
    }

    /// launch/activate の前に確かめる(門は InstalledAppCheck.launchGuard の1箇所。MCP の
    /// ft_launch と同じ判定・文言だけ呼び手ごと)。未インストールのまま
    /// `XCUIApplication.launch()` を撃つとランナーが約60秒でハングして自壊する(実測 L2)。
    /// own app(hybrid で in-app が既に繋がっているアプリ)への launch/activate は素通しする ——
    /// in-app は XCUITest を経由せず、繋がっている時点でインストール済みが確定している
    private func launchGuard(bundle: String, driver: AppDriver, ownAppBundleID: String?) async throws {
        guard bundle != ownAppBundleID else { return }
        let isAndroid = driverOptions.resolvedPlatform == "android"
        let verdict: InstalledAppCheck.InstallVerdict
        if isAndroid {
            if let android = driver as? AndroidDriver, let installed = android.isInstalled(bundleID: bundle) {
                verdict = installed ? .installed : .notInstalled
            } else {
                verdict = .unknown("adb")
            }
        } else if let udid {
            // 実機は simctl ではなく devicectl(§19.3 M8 と同じ切り分け。simctl に実機の udid を
            // 渡すと的外れな失敗になる)
            if SimulatorCatalog.isPhysical(udid: udid) == true {
                if let apps = try? IOSPhysicalAppCatalog.apps(udid: udid) {
                    verdict = apps.contains { $0.id == bundle } ? .installed : .notInstalled
                } else {
                    verdict = .unknown("devicectl could not list installed apps")
                }
            } else {
                verdict = InstalledAppCheck.simulatorInstallVerdict(udid: udid, bundleID: bundle)
            }
        } else {
            verdict = .unknown("no udid to check installation with")
        }
        switch InstalledAppCheck.launchGuard(
            verdict: verdict, isAndroid: isAndroid, engine: isAndroid ? nil : "xcuitest", bundleID: bundle) {
        case .allow:
            return
        case .refuse(.notInstalled):
            throw ServeCommandError.invalidArguments(
                "\(bundle) is not installed on this device."
                + " Install it first with {\"cmd\":\"install\",\"path\":\"<.app or .apk>\"},"
                + " or check the bundle ID.")
        case .refuse(.unknown(let reason)):
            throw ServeCommandError.invalidArguments(
                "could not verify whether \(bundle) is installed (\(reason))."
                + " Launching a missing app can hang the XCUITest bridge and force it to"
                + " self-terminate — retry once the device is less busy, install it first,"
                + " or double-check the bundle ID.")
        }
    }

    /// x/y 座標が今の画面の外なら断る(判定は `TapTargetGeometry.isPointOnScreen` = MCP の
    /// `offscreenCoordinateError` と共有。`LiveControlExitParityTests.sharedJudgements`)。
    /// 門が無いと桁外れの座標が Android の最後の砦まで届き、利用者には「範囲外」としか返せない。
    /// **画面の大きさは直近の観測の控え(`screenMemo`)で見る** —— パネルのクリックは座標の tap なので、
    /// 毎回 snapshot を撮るとクリックのたびに木を1回余分に読む(MCP の `coordinateScreen` と同じ考え方)。
    /// **控えで外れたときだけ撮り直して確かめる**(回転の直後など控えが古い回に正当なクリックを断らない)
    private func requireOnScreen(_ points: [(x: Double, y: Double)], driver: AppDriver,
                                 screenMemo: LiveScreenMemo) async throws {
        guard !points.isEmpty else { return }
        if let remembered = await screenMemo.screen,
           points.allSatisfy({ TapTargetGeometry.isPointOnScreen(x: $0.x, y: $0.y, screen: remembered) }) {
            return
        }
        let screen = try await driver.snapshot().screen
        await screenMemo.note(screen)
        for point in points
            where !TapTargetGeometry.isPointOnScreen(x: point.x, y: point.y, screen: screen) {
            throw ServeCommandError.invalidArguments(
                "(\(FTSeconds.format(point.x)), \(FTSeconds.format(point.y))) is outside the screen"
                + " (\(FTSeconds.format(screen.width))x\(FTSeconds.format(screen.height))) —"
                + " refusing to send it. Take a fresh screenshot and click inside the visible screen.")
        }
    }

    /// コマンドに応じたドライバ操作を実行する。引数不足・未知の cmd は ServeCommandError を投げる
    /// (呼び出し元 handle が actionResult の ok:false として拾う)
    private func perform(command: ApiLiveServeCommand, driver: AppDriver,
                         follower: LiveSessionFollower?, ownAppBundleID: String?,
                         screenMemo: LiveScreenMemo) async throws {
        if Self.followsFrontmost(command.cmd) { await follower?.follow(driver: driver) }
        switch command.cmd {
        case "tap":
            if let ref = command.ref {
                try await driver.tap(ref: ref)
            } else if let x = command.x, let y = command.y {
                try await requireOnScreen([(x, y)], driver: driver, screenMemo: screenMemo)
                try await driver.tap(x: x, y: y)
            } else {
                throw ServeCommandError.invalidArguments("tap requires ref or x/y")
            }
        case "type":
            guard let text = command.text else {
                throw ServeCommandError.invalidArguments("type requires text")
            }
            try await driver.type(ref: command.ref, text: text)
        case "clear":
            try await driver.clearInput(ref: command.ref)
        case "hideKeyboard":
            try await driver.hideKeyboard()
        case "swipe":
            guard let raw = command.direction, let direction = FTSwipeDirection(rawValue: raw) else {
                throw ServeCommandError.invalidArguments(
                    "swipe direction must be one of up/down/left/right")
            }
            try await driver.swipe(direction)
        case "drag":
            guard let fromX = command.fromX, let fromY = command.fromY,
                  let toX = command.toX, let toY = command.toY else {
                throw ServeCommandError.invalidArguments("drag requires fromX/fromY/toX/toY")
            }
            try await requireOnScreen([(fromX, fromY), (toX, toY)], driver: driver, screenMemo: screenMemo)
            try await driver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: command.press ?? ApiLiveGestureDefaults.dragPressSeconds,
                                  durationSeconds: command.duration ?? ApiLiveGestureDefaults.dragDurationSeconds)
        case "doubleTap":
            // **座標へ畳んでから撃つ**(ref はブリッジごとに別名前空間。AppDriver.doubleTap の注記参照)
            if let ref = command.ref {
                let element = try await Self.element(ref: ref, driver: driver)
                try await driver.doubleTap(x: element.frame.centerX, y: element.frame.centerY)
            } else if let x = command.x, let y = command.y {
                try await requireOnScreen([(x, y)], driver: driver, screenMemo: screenMemo)
                try await driver.doubleTap(x: x, y: y)
            } else {
                throw ServeCommandError.invalidArguments("doubleTap requires ref or x/y")
            }
        case "pinch":
            let scale = command.scale ?? 2.0
            guard scale > 0, scale != 1, scale.isFinite else {
                throw ServeCommandError.invalidArguments(
                    "pinch scale must be positive and not 1 (>1 zooms in, <1 zooms out)")
            }
            let duration = command.duration ?? ApiLiveGestureDefaults.pinchDurationSeconds
            if let ref = command.ref {
                // ref 指定時は frame と identifier の両方を渡す(経路で対象の伝え方が違う。
                // FTCore/BridgeDTO の PinchRequest)
                let element = try await Self.element(ref: ref, driver: driver)
                try await driver.pinch(frame: element.frame, identifier: element.identifier,
                                       scale: scale, durationSeconds: duration)
            } else {
                // **指の2点が別々のものに載らない位置を選ぶ**(実測と理由は PinchRegion)。
                // Android は領域の短辺から指の幅を決めるので渡さない。**絞れなくても画面矩形は渡す**
                // —— 領域があれば座標で撃てる(端ちょうどには置かない)= DSL と同じ扱いにする
                let snapshot = try await driver.snapshot()
                let area = driverOptions.resolvedPlatform == "ios"
                    ? (PinchRegion.area(elements: snapshot.elements, screen: snapshot.screen)
                        ?? snapshot.screen)
                    : nil
                try await driver.pinch(frame: area, identifier: nil, scale: scale,
                                       durationSeconds: duration)
            }
        case "press":
            guard let x = command.x, let y = command.y, let duration = command.duration else {
                throw ServeCommandError.invalidArguments("press requires x/y/duration")
            }
            try await requireOnScreen([(x, y)], driver: driver, screenMemo: screenMemo)
            try await driver.press(x: x, y: y, duration: duration)
        case "gesture":
            // **判定は TouchGesture.validate の1箇所**(MCP の ft_gesture と共有。DSL/MCP/ライブ操作の
            // 3経路が同じ門を通る)。座標は webview が既に device 座標へ換算済み(このコマンドの唯一の
            // 発生源は軌跡モード)なので、resolve(比率写像)は経由せず validate へ直接渡す
            guard let fingers = command.fingers, !fingers.isEmpty else {
                throw ServeCommandError.invalidArguments("gesture requires a non-empty fingers array")
            }
            let gestureScreen = try await driver.snapshot().screen
            let cap = command.maxGestureSeconds ?? BridgeAPI.defaultMaxGestureSeconds
            switch TouchGesture.validate(GestureRequest(fingers: fingers), screen: gestureScreen,
                                         maxGestureSeconds: cap) {
            case .failure(let rejection):
                throw ServeCommandError.invalidArguments(rejection.message)
            case .success(let validated):
                try await driver.gesture(validated)
            }
        case "launch":
            guard let bundle = command.bundle, !bundle.isEmpty else {
                throw ServeCommandError.invalidArguments("launch requires a non-empty bundle")
            }
            try await launchGuard(bundle: bundle, driver: driver, ownAppBundleID: ownAppBundleID)
            try await driver.launch(bundleID: bundle)
            follower?.noteSessionChanged(to: bundle)
        case "activate":
            guard let bundle = command.bundle, !bundle.isEmpty else {
                throw ServeCommandError.invalidArguments("activate requires a non-empty bundle")
            }
            try await launchGuard(bundle: bundle, driver: driver, ownAppBundleID: ownAppBundleID)
            try await driver.activate(bundleID: bundle)
            follower?.noteSessionChanged(to: bundle)
        case "appSwitcher":
            try await driver.openAppSwitcher()
        case "home":
            try await driver.home()
        case "back":
            try await driver.back()
        case "terminate":
            // **セッションの向き先を対象に撃つ**ので、追従で springboard を向いていたら戻す。
            // 駆動しているアプリが無ければ**断る** —— そのまま撃つと SpringBoard を終了させる
            if let follower {
                guard let target = follower.drivenApp() else {
                    throw ServeCommandError.invalidArguments(
                        "terminate needs an app in this session — launch one first")
                }
                try await follower.pointAtApp(target, driver: driver)
            }
            try await driver.terminate()
            follower?.noteSessionDropped()
        case "clearAppData":
            let bundle = try await resolveBundleForClearAppData(
                command: command, driver: driver, follower: follower)
            // clearAppData はホスト側で `terminate()`(= セッションのアプリ)を撃ってから
            // コンテナを消すので、対象のアプリへセッションを寄せてからでないと別のものを殺す
            try await follower?.pointAtApp(bundle, driver: driver)
            try await driver.clearAppData(bundleID: bundle)
            follower?.noteSessionDropped()
        case "install":
            guard let path = command.path else {
                throw ServeCommandError.invalidArguments("install requires path")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw ServeCommandError.invalidArguments("package file not found: \(path)")
            }
            // 中身が同じなら入れ直さない(run 側 BridgeProvisioner と同じ規律)。
            // 再インストールはアプリを終了させ、記録開始のたびに状態が消えるため
            if driverOptions.resolvedPlatform == "ios", let udid,
               let bundleID = Self.bundleID(inAppBundle: path),
               InstalledAppCheck.simulatorAppIsCurrent(
                   udid: udid, bundleID: bundleID, appPath: path) {
                logStderr("→ install: skipped (contents identical to the installed app): \(bundleID)")
                return
            }
            try await driver.install(packagePath: path)
            if driverOptions.resolvedPlatform == "ios", let udid,
               let bundleID = Self.bundleID(inAppBundle: path) {
                InstalledAppCheck.recordInstalled(udid: udid, bundleID: bundleID, appPath: path)
            }
        default:
            throw ServeCommandError.invalidArguments("unknown cmd: \(command.cmd)")
        }
    }

    /// bundle 省略時は**パネルが駆動しているアプリ**、それも無ければセッションが指すアプリ
    /// (/status.sessionBundleID)を対象にする。どちらも取れなければ引数不足として扱う
    /// (terminate と違い clearAppData は bundleID が必須のため)
    private func resolveBundleForClearAppData(
        command: ApiLiveServeCommand, driver: AppDriver, follower: LiveSessionFollower?
    ) async throws -> String {
        if let bundle = command.bundle { return bundle }
        // **追従役の preferred が先** —— セッションは springboard を向いていることがあり、
        // そのまま既定にすると SpringBoard のデータを消す対象になる
        if let preferred = follower?.drivenApp() { return preferred }
        guard let sessionBundleID = try? await driver.status().sessionBundleID,
              sessionBundleID != LiveSessionTarget.springboard else {
            throw ServeCommandError.invalidArguments(
                "clearAppData requires bundle (no active session to infer it from)")
        }
        return sessionBundleID
    }

    /// スクリーンショット(ダウンスケール済み JPEG)とアクセシビリティツリーを観測イベントとして出す
    /// (MonitorImage.swift の MonitorImage を共有利用する)。refresh(ユーザーの「更新」
    /// ボタン)はこの経路しか通らないため、ここでの自動起動トリガーは必須。
    /// **鮮度判定(StaleFrameDetector)はここだけ**——絵と木の両方を撮るのはこの経路だけで、
    /// emitFrame は絵だけなので判定できない
    private func emitObservation(driver: AppDriver, starter: LiveBridgeAutoStarter?,
                                 follower: LiveSessionFollower?, port: UInt16,
                                 staleFrameTracker: LiveStaleFrameTracker,
                                 screenMemo: LiveScreenMemo) async {
        do {
            let png = try await driver.screenshot()
            let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
            let snap = try await snapshotWithSessionFallback(driver: driver, follower: follower)
            let elements = snap.elements.map {
                ApiLiveElement(ref: $0.ref, type: $0.type, label: $0.label,
                               identifier: $0.identifier, value: $0.value, frame: $0.frame)
            }
            let notes = await staleFrameTracker.staleNotes(png: png, elements: snap.elements)
            await screenMemo.note(snap.screen)
            emitLine(ApiLiveSnapshotEvent(
                ok: true, error: nil,
                platform: driverOptions.resolvedPlatform,
                screen: ApiLiveScreenSize(width: snap.screen.width, height: snap.screen.height),
                image: jpeg.data.base64EncodedString(), elements: elements, notes: notes,
                bridgeStarting: await bridgeStartingFlag(starter)))
        } catch {
            let message = await annotated(error, starter: starter, triggering: true, port: port)
            // **annotated の後で読む**(bridgeStartingFlag のコメント参照)
            emitLine(ApiLiveSnapshotEvent(
                ok: false, error: message,
                platform: nil, screen: nil, image: nil, elements: nil, notes: [],
                bridgeStarting: await bridgeStartingFlag(starter)))
        }
    }

    /// スクリーンショットのみの観測イベント(kind:"frame")。自動画面更新用に AX スナップショット
    /// を省いて軽量化している(要素一覧は更新されない=鮮度判定に要る木が無いので撃たない)。
    /// 自動フレームは受動的観測のため起動はトリガーせず、starter の既知の状態を bridgeStarting へ
    /// 反映する(failed のときだけ error にも文言が付く)
    private func emitFrame(driver: AppDriver, starter: LiveBridgeAutoStarter?, port: UInt16) async {
        do {
            let png = try await driver.screenshot()
            let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
            emitLine(ApiLiveFrameEvent(ok: true, error: nil, image: jpeg.data.base64EncodedString(),
                                       bridgeStarting: await bridgeStartingFlag(starter)))
        } catch {
            let message = await annotated(error, starter: starter, triggering: false, port: port)
            // **annotated の後で読む**(bridgeStartingFlag のコメント参照)
            emitLine(ApiLiveFrameEvent(ok: false, error: message, image: nil,
                                       bridgeStarting: await bridgeStartingFlag(starter)))
        }
    }

    /// 木が読めない2つの状態から springboard 参照セッション(起動せず・非破壊。
    /// SystemUIDriver.swift と同じ経路)で回復し、1回だけ再試行する:
    ///   - **409**: セッション未作成(ライブ操作はデバイス選択直後などアプリ未起動のまま観測しうる)
    ///   - **422**: セッションのアプリが前面でない(BridgeRouter.requireForegroundApp)。
    ///     **ライブ操作では普通に起きる** —— 利用者はいつでも画面を切り替えるので、前面追従が
    ///     向けた直後に外れることがある。springboard は背面に回らないので必ず読める
    /// それ以外(タイムアウト等)で再試行しないのは、生きている既存アプリセッションを
    /// springboard で上書きしないため。
    /// **follower にも伝える** —— 黙って倒すと「まだあのアプリを向いている」と思い続け、
    /// 次の追従が「向き先は変わっていない」と判断して撃たない
    private func snapshotWithSessionFallback(driver: AppDriver,
                                             follower: LiveSessionFollower?) async throws -> SnapshotResponse {
        do {
            return try await driver.snapshot()
        } catch DriverError.badResponse(let status, _)
                    where (status == 409 || status == 422) && Self.usesSpringboardFallback(platform: driverOptions.resolvedPlatform) {
            try await driver.launch(bundleID: LiveSessionTarget.springboard)
            follower?.noteSessionChanged(to: LiveSessionTarget.springboard)
            return try await driver.snapshot()
        }
    }

    /// **springboard への退避は iOS だけ**。Android の 422 は「アクティブウィンドウの a11y 根が無い」
    /// (`DriverError.isNoReadableWindow`。アプリスイッチャー表示中などで普通に起きる)で、そこへ
    /// `com.apple.springboard` の launch を撃つと 500「cannot launch the app」に化け、元の事実と
    /// 自然回復の案内(noReadableWindowHint)が消えていた(実地 2026-09-24・Pixel 3a)
    static func usesSpringboardFallback(platform: String) -> Bool {
        platform == "ios"
    }

    private func logStderr(_ message: String) {
        ConsoleOut.err("[live serve] " + message)
    }
}

/// emitObservation が撮る絵(PNG)と木を FTCore.StaleFrameDetector へ渡し、直前の記録と比べる
/// (二つ目の判定は書かない。契約は StaleFrameDetector.swift のコメント参照)。serve は1プロセスが
/// 1台を見続けるので、MCP の engineKey 付き辞書と違い記録は1つで足りる。
/// **not private**(テストが `@testable import fleetest` で直接呼ぶため)
actor LiveStaleFrameTracker {
    private var previous: StaleFrameDetector.Record? = nil

    /// isStale なら利用者向けの注記を1件だけ返す(無ければ空配列)。呼ぶたびに記録を今回分へ
    /// 更新する(StaleFrameDetector.judge と同じ契約 = 同じ凍結フレームへの注記は最初の1回だけ)
    func staleNotes(png: Data, elements: [ElementInfo]) -> [String] {
        let (record, isStale) = StaleFrameDetector.judge(png: png, elements: elements, previous: previous)
        previous = record
        guard isStale else { return [] }
        return ["this screenshot may be stale: the element tree changed since the previous"
            + " observation, but the image is byte-identical to the previous one — the display may"
            + " be frozen on an old frame. Don't trust what's on screen from this image alone;"
            + " interact again (or refresh) and see whether the picture actually changes."]
    }
}

/// 直近の観測で得た画面の大きさ(`requireOnScreen` が毎クリック snapshot を撮らないための控え)。
/// serve は1プロセス1台なので1つで足りる
actor LiveScreenMemo {
    private(set) var screen: FTRect?
    func note(_ screen: FTRect) { self.screen = screen }
}

/// 引数不足・未知の cmd 等、コマンドの中身が不正なときのエラー(JSON 自体は壊れていない場合)
private enum ServeCommandError: Error, LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        }
    }
}

/// 1行 JSON を stdout に出力する(ApiMonitorCommand.emitLine と同方針。withoutEscapingSlashes は
/// snapshot の image(base64。"/" を含みうる)向け)
private func emitLine<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8) else { return }
    ConsoleOut.out(line)
}

// MARK: - stdin コマンド

/// press/drag/pinch の秒数引数を省略したときの既定値。**perform() と
/// ApiLiveServeCommand.gestureAllowanceSeconds が同じ値を使うこと** —— 片方だけ変えると
/// 実際に撃つジェスチャの所要と command watchdog の許容がずれ、正当な長さの
/// ドラッグ/ピンチが watchdog に途中で殺されうる
enum ApiLiveGestureDefaults {
    /// drag の「押下してから動かし始めるまでの静止時間」既定[秒]
    static let dragPressSeconds: Double = 0.05
    /// drag の「移動にかける時間」既定[秒]
    static let dragDurationSeconds: Double = 0.3
    /// pinch の「変形にかける時間」既定[秒]
    static let pinchDurationSeconds: Double = 0.5
}

/// stdin から受け取る1コマンド分(NDJSON 1行)。cmd 以外は全コマンド共通のオプショナルとし、
/// 必須引数の欠落は perform(command:driver:) がコマンド種別毎に判定する(フィールド欠落は
/// actionResult の ok:false として1件だけ失敗させるため)。
///
/// **JSONDecoder ではなく [String: Any] から手で組む**: 型付き Decodable だと1フィールドでも
/// 型が違うと decode 全体が失敗し、cmd さえ読めていた行も「JSON でない」行と見分けが付かず
/// 無応答のまま黙殺していた(実地 L3: `{"cmd":"pinch","scale":"2"}` が無反応 → 拡張の
/// SERVE_REQUEST_TIMEOUT で serve ごと再起動)。ここでは cmd 以外の型違いを decodeError に
/// 残し、handle が actionResult(ok:false)で答える。
/// **private ではない**(テストが `@testable import fleetest` で直接組み立てて検査するため)
struct ApiLiveServeCommand {
    let cmd: String
    let ref: Int?
    let x: Double?
    let y: Double?
    let text: String?
    let direction: String?
    let bundle: String?
    let path: String?
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    let press: Double?
    let duration: Double?
    let scale: Double?
    /// press/drag/pinch の秒数上限をこの1回だけ引き上げる(nil = 既定
    /// `BridgeAPI.defaultMaxGestureSeconds` = 10 秒。最大 `BridgeAPI.gestureSecondsCeiling` = 60 秒)
    let maxGestureSeconds: Double?
    /// gesture コマンド専用(ワイヤ形は GestureRequest.fingers そのまま)。座標は既に device 座標
    /// (webview 側で pointFromClick を通した後)なので、ここでは比率写像を経由しない
    let fingers: [GestureFinger]?
    /// 型違いの引数のうち1件目の説明(無ければ nil)。cmd 自体はこの型を作れている時点で読めている
    let decodeError: String?

    /// このコマンドが正当に占有しうる時間[秒]。command watchdog の allowance
    /// (`ResidentProcessGuard.noteCommandStart(allowanceSeconds:)`)に渡す。
    /// **press/drag/pinch/gesture だけが対象** —— これらは `BridgeClient.timeout(forDuration:)` で
    /// 実行時間ぶん HTTP タイムアウトを伸ばして撃つため、固定の watchdog 基準値
    /// (`ApiLiveServe.commandWatchdogMaxSeconds`)だけでは正当な長い指定
    /// (例: `maxGestureSeconds` で最大60秒)を待ち切れず、まだ実行中のジェスチャを watchdog が
    /// force-quit してしまう。**他のコマンドは 0**(固定の watchdog 基準値だけで足りる)。
    /// 既定値は perform() と同じ `ApiLiveGestureDefaults` を使う(1箇所)
    var gestureAllowanceSeconds: Double {
        switch cmd {
        case "gesture":
            return fingers.map { GestureRequest(fingers: $0).totalSeconds } ?? 0
        case "press":
            return duration ?? 0
        case "drag":
            return (press ?? ApiLiveGestureDefaults.dragPressSeconds)
                + (duration ?? ApiLiveGestureDefaults.dragDurationSeconds)
        case "pinch":
            return duration ?? ApiLiveGestureDefaults.pinchDurationSeconds
        default:
            return 0
        }
    }

    init(cmd: String, raw: [String: Any]) {
        self.cmd = cmd
        var error: String?
        ref = Self.intField(raw, "ref", error: &error)
        x = Self.doubleField(raw, "x", error: &error)
        y = Self.doubleField(raw, "y", error: &error)
        text = Self.stringField(raw, "text", error: &error)
        direction = Self.stringField(raw, "direction", error: &error)
        bundle = Self.stringField(raw, "bundle", error: &error)
        path = Self.stringField(raw, "path", error: &error)
        fromX = Self.doubleField(raw, "fromX", error: &error)
        fromY = Self.doubleField(raw, "fromY", error: &error)
        toX = Self.doubleField(raw, "toX", error: &error)
        toY = Self.doubleField(raw, "toY", error: &error)
        press = Self.doubleField(raw, "press", error: &error)
        duration = Self.doubleField(raw, "duration", error: &error)
        scale = Self.doubleField(raw, "scale", error: &error)
        maxGestureSeconds = Self.doubleField(raw, "maxGestureSeconds", error: &error)
        fingers = Self.fingersField(raw, "fingers", error: &error)
        // **秒数の相互検査は値域(doubleField)の隣**(MCPServer.call と同じ入口の粒度。
        // ArgumentBounds.gestureCapViolation は BridgeAPI の2関数を呼ぶだけ)
        if error == nil, let violation = ArgumentBounds.gestureCapViolation(raw) {
            error = violation
        }
        decodeError = error
    }

    /// "fingers"(gesture コマンド専用)。ワイヤ形は `GestureRequest.fingers` と同じ
    /// (`[{"points":[{"x":..,"y":..,"t":..}, ...]}, ...]`)。積み上げ・本数・時刻の単調性・画面内の
    /// 検査は `TouchGesture.validate` に委ねる(重複させない)—— ここは型違いだけを見る
    private static func fingersField(
        _ raw: [String: Any], _ key: String, error: inout String?
    ) -> [GestureFinger]? {
        guard let value = raw[key] else { return nil }
        guard let rawFingers = value as? [Any] else {
            if error == nil { error = typeError(key: key, value: value, expected: "an array", numeric: false) }
            return nil
        }
        var fingers: [GestureFinger] = []
        for (fingerIndex, rawFinger) in rawFingers.enumerated() {
            guard let fingerDict = rawFinger as? [String: Any] else {
                if error == nil {
                    error = "\(key)[\(fingerIndex)] must be an object (got \(describeValue(rawFinger)))"
                }
                return nil
            }
            guard let rawPoints = fingerDict["points"] as? [Any] else {
                if error == nil { error = "\(key)[\(fingerIndex)].points must be an array" }
                return nil
            }
            var points: [GesturePoint] = []
            for (pointIndex, rawPoint) in rawPoints.enumerated() {
                guard let pointDict = rawPoint as? [String: Any],
                      let x = numberValue(pointDict["x"]), let y = numberValue(pointDict["y"]),
                      let t = numberValue(pointDict["t"]) else {
                    if error == nil {
                        error = "\(key)[\(fingerIndex)].points[\(pointIndex)] must be an object with"
                            + " numeric x/y/t"
                    }
                    return nil
                }
                points.append(GesturePoint(x: x, y: y, t: t))
            }
            fingers.append(GestureFinger(points: points))
        }
        return fingers
    }

    /// {"scale":2} のような整数値も number として通す(NSNumber は Int/Double のどちらでも来うる)
    private static func numberValue(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    /// 型違い・値域違反とも1件目のエラー文だけを残す(複数同時に違っても最初の1つで足りる)。
    /// **値がおかしいときは常に nil を返す**(error が既に埋まっていても)—— 「1件目の文言」と
    /// 「この値をなだれ込ませるか」は別の軸。文言は MCP(MCPServer.intArgument/doubleArgument)と
    /// 揃える(2026-09-22 L3)。**型が合っていても値域(`ArgumentBounds`)を外れれば同じく断る**
    /// (MCP と同じ表を引く — 2箇所に値を持たない)
    private static func intField(_ raw: [String: Any], _ key: String, error: inout String?) -> Int? {
        guard let value = raw[key] else { return nil }
        guard let number = value as? Int else {
            if error == nil { error = typeError(key: key, value: value, expected: "an integer", numeric: true) }
            return nil
        }
        if let violation = ArgumentBounds.violation(key, Double(number)) {
            if error == nil { error = violation }
            return nil
        }
        return number
    }

    private static func doubleField(_ raw: [String: Any], _ key: String, error: inout String?) -> Double? {
        guard let value = raw[key] else { return nil }
        // {"scale":2} のような整数値も通す
        guard let number = (value as? Double) ?? (value as? Int).map(Double.init) else {
            if error == nil { error = typeError(key: key, value: value, expected: "a number", numeric: true) }
            return nil
        }
        if let violation = ArgumentBounds.violation(key, number) {
            if error == nil { error = violation }
            return nil
        }
        return number
    }

    /// 型が合っていても `ArgumentBounds.mustNotBeEmpty` に載っている鍵(bundle/path)は
    /// 明示された空文字・空白のみを断る。**cmd を問わず一律**(decode 段は cmd を見ない)——
    /// clearAppData の bundle / install の path はここで初めて空文字が断られる(従来は無検査だった)
    private static func stringField(_ raw: [String: Any], _ key: String, error: inout String?) -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String else {
            if error == nil { error = typeError(key: key, value: value, expected: "a string", numeric: false) }
            return nil
        }
        if let violation = ArgumentBounds.emptyViolation(key, string) {
            if error == nil { error = violation }
            return nil
        }
        return string
    }

    private static func typeError(key: String, value: Any, expected: String, numeric: Bool) -> String {
        let hint = numeric ? "a JSON number, not a quoted string" : "a JSON string, not a number"
        return "\(key) must be \(expected) (got \(describeValue(value))) — pass \(hint)"
    }

    /// MCPServer.describeArgumentValue と同じ書式(型が分かる形。文字列 "8" と数値 8 を見分ける)
    private static func describeValue(_ value: Any) -> String {
        switch value {
        case let value as String: return "the string \"\(value)\""
        case let value as Bool: return "the boolean \(value)"
        case is [Any]: return "an array"
        case is [String: Any]: return "an object"
        case is NSNull: return "null"
        default: return "\(value)"
        }
    }
}

// MARK: - JSON 出力(イベント)

/// actionResult イベント(refresh 以外の全コマンド共通)。app = その操作を撃った先
/// (セッションの向き先。ファイル冒頭のプロトコル参照)
private struct ApiLiveActionResultEvent: Encodable {
    let kind = "actionResult"
    let ok: Bool
    let error: String?
    let app: String?
    /// LiveBridgeAutoStarter.isStarting(ファイル冒頭プロトコル・bridgeStartingFlag 参照)
    let bridgeStarting: Bool

    private enum CodingKeys: String, CodingKey { case kind, ok, error, app, bridgeStarting }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(app, forKey: .app)
        try container.encode(bridgeStarting, forKey: .bridgeStarting)
    }
}

extension ApiLiveServe {
    /// .app/Info.plist の CFBundleIdentifier。取れなければ nil(= 差分判定をあきらめて素直に入れる)
    static func bundleID(inAppBundle path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return object["CFBundleIdentifier"] as? String
    }
}

/// snapshot(観測)イベント。ok:true 時は platform/screen/image/elements が必ず埋まり、ok:false 時は
/// それらが null になる。**notes は elements と違い null にしない**(注記が無い回は常に空配列 ——
/// 拡張側に「無い」と「まだ知らない」を区別させない)
private struct ApiLiveSnapshotEvent: Encodable {
    let kind = "snapshot"
    let ok: Bool
    let error: String?
    let platform: String?
    let screen: ApiLiveScreenSize?
    let image: String?
    let elements: [ApiLiveElement]?
    let notes: [String]
    /// LiveBridgeAutoStarter.isStarting(ファイル冒頭プロトコル・bridgeStartingFlag 参照)
    let bridgeStarting: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error, platform, screen, image, elements, notes, bridgeStarting
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(platform, forKey: .platform)
        try container.encode(screen, forKey: .screen)
        try container.encode(image, forKey: .image)
        try container.encode(elements, forKey: .elements)
        try container.encode(notes, forKey: .notes)
        try container.encode(bridgeStarting, forKey: .bridgeStarting)
    }
}

/// frame(画像のみ観測)イベント。ok:true 時は image が必ず埋まる
private struct ApiLiveFrameEvent: Encodable {
    let kind = "frame"
    let ok: Bool
    let error: String?
    let image: String?
    /// LiveBridgeAutoStarter.isStarting(ファイル冒頭プロトコル・bridgeStartingFlag 参照)
    let bridgeStarting: Bool

    private enum CodingKeys: String, CodingKey { case kind, ok, error, image, bridgeStarting }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(image, forKey: .image)
        try container.encode(bridgeStarting, forKey: .bridgeStarting)
    }
}

/// screen はポイント座標のサイズのみ(位置は常に (0,0) 起点のため x/y は出さない)
private struct ApiLiveScreenSize: Encodable {
    let width: Double
    let height: Double
}

/// snapshot の 1 要素分。省略可能フィールド(label/identifier/value)は JSON 上で "null" を
/// 明示する(ApiScenarioInfo と同方針。synthesized Encodable の encodeIfPresent は使わない)。
/// frame は FTElement(ElementInfo)に常に存在するフィールドなので省略しない
private struct ApiLiveElement: Encodable {
    let ref: Int
    let type: String
    let label: String?
    let identifier: String?
    let value: String?
    let frame: FTRect

    private enum CodingKeys: String, CodingKey {
        case ref, type, label, identifier, value, frame
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(type, forKey: .type)
        try container.encode(label, forKey: .label)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(value, forKey: .value)
        try container.encode(frame, forKey: .frame)
    }
}
