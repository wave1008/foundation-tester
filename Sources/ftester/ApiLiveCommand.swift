// VSCode拡張のライブ操作パネル向け常駐 CLI(ftester api live serve)。ドライバを起動時に
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
//   {"cmd":"swipe","direction":"up"|"down"|"left"|"right"}
//   {"cmd":"drag","fromX":..,"fromY":..,"toX":..,"toY":..,"press":<秒省略可>,"duration":<秒省略可>}
//                                                        2点間ドラッグ(座標はpt。press=押下静止時間、duration=移動時間)
//   {"cmd":"press","x":<Double>,"y":<Double>,"duration":<秒>}  座標ロングプレス
//   {"cmd":"launch","bundle":<String>}                  bundle ID / パッケージ名を起動
//   {"cmd":"activate","bundle":<String>}               状態を保持したまま前面切替(未起動なら起動)
//   {"cmd":"appSwitcher"}                               アプリスイッチャー(タスク一覧)を開く
//   {"cmd":"home"}                                       ホーム画面に戻る
//   {"cmd":"back"}                                       前の画面へ戻る
//   {"cmd":"terminate"}                                 対象アプリを終了
//   {"cmd":"install","path":<String>}                   パッケージファイル(iOS: .app / Android: .apk)
//                                                        からインストール
//   {"cmd":"refresh"}                                   操作は行わず観測のみ
//   {"cmd":"frame"}                                     スクリーンショットのみ取得(AXツリーは取らない)
// 壊れた行(JSON でない、cmd が無い)は stderr に1行ログして無視する(他の常駐 api コマンドと同じ
// 「安全側で無視する」方針)。
//
// イベント(serve → stdout、1行1JSON。診断は stderr のみ):
//   refresh 以外のコマンドはまず
//     {"kind":"actionResult","ok":true,"error":null}
//     {"kind":"actionResult","ok":false,"error":"<説明>"}
//   のどちらかを出し、続けて(操作の成否を問わず)観測イベント
//     {"kind":"snapshot","ok":true,"error":null,"platform":"ios"|"android",
//      "screen":{"width":..,"height":..},"image":"<base64 JPEG>",
//      "elements":[{"ref":..,"type":"..","label":..|null,"identifier":..|null,"value":..|null,
//                    "frame":{"x":..,"y":..,"width":..,"height":..}}, ...]}
//     {"kind":"snapshot","ok":false,"error":"<説明>","platform":null,"screen":null,"image":null,
//      "elements":null}
//   を出す(操作後の追加waitは無し。ブリッジの操作応答=UI整定済みのため)。
//   refresh はこの観測イベント1行だけを出す(actionResult は出さない)。
//   frame は {"kind":"frame","ok":..,"error":..,"image":"<base64 JPEG>"|null} の1行だけを出す
//   (actionResult・snapshot は出さない。ライブ操作パネルの自動画面更新用)。
//   拡張側は actionResult が ok:false のとき、続く snapshot イベントは画面へ反映しない
//   (直前の表示を保持したままエラーを表示する)。
//
// 座標契約: snapshot の screen / elements[].frame はポイント座標。
//
// 終了: stdin EOF、または SIGTERM/SIGINT(setvbuf の行バッファ化含め他の常駐 api コマンドと同じ
// 流儀)。ただしこちらは周期処理を持たないコマンド駆動のため、StopFlag+ポーリングではなく
// AsyncStream で橋渡しし SIGTERM/SIGINT は continuation.finish() で for-await を抜けさせる。
//
// --udid(iOS のみ): 指定時、DriverError.bridgeConnectionRefused を tap 等の実行時・観測
// (emitObservation)時に検知すると LiveBridgeAutoStarter がブリッジを自動起動し、起動状況を
// エラー文言に付記する(詳細は LiveBridgeAutoStarter.swift)。自動フレーム(emitFrame)は状況
// 付記のみで起動はトリガーしない。serve 起動時に /status の protocolVersion を確認し、
// 旧ビルドのブリッジは自動で再起動する。

import ArgumentParser
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

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(他の常駐 api コマンドと同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "live serve")
        // 1コマンドが wedge(CPU spin 等)しても自死できる最終安全弁。30秒 > 拡張の
        // SERVE_REQUEST_TIMEOUT_MS(20秒)にして、通常は拡張の kill→respawn を先に効かせる。
        ResidentProcessGuard.startCommandWatchdog(maxSeconds: 30, logLabel: "live serve")

        let (driver, port) = try await makeDriverAvoidingInApp()
        let starter = makeAutoStarter(port: port)
        if let starter {
            Task { await starter.checkAndRestartIfStale() }
        }

        let (lines, continuation) = AsyncStream<String>.makeStream(of: String.self)
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                continuation.yield(line)
            }
            continuation.finish()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "live serve")
        }
        reader.name = "ftester-api-live-serve-stdin"
        reader.start()

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "ftester-api-live-serve-signal")
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
            guard let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(ApiLiveServeCommand.self, from: data) else {
                logStderr("Ignored a line in an unknown format: \(line)")
                continue
            }
            ResidentProcessGuard.noteCommandStart()
            await handle(command: command, driver: driver, starter: starter)
            ResidentProcessGuard.noteCommandEnd()
        }
    }

    /// live は home/appSwitcher/drag/座標 press を扱うため **in-app ブリッジを使わない**。
    /// 指定ポートが in-app なら同じデバイスの XCUITest ブリッジへ振り替える(XCUIBridgeResolver)。
    /// 戻り値のポートは以後の自動起動・再起動が同じ宛先を見るために返す
    private func makeDriverAvoidingInApp() async throws -> (AppDriver, UInt16) {
        guard driverOptions.platform == "ios" else {
            return (try driverOptions.makeDriver(), driverOptions.port)
        }
        // **autoStart:false**(= 走査までで止める)。serve は常駐で、拡張は応答が無いと
        // kill→respawn するため、起動時に build-for-testing(分単位)でブロックしてはいけない。
        // hybrid は in-app と XCUITest を両方張るので走査だけで必ず見つかる。
        // 見つからないのは engine=inapp 単独のときで、そのときは理由を stderr に出して素通しする
        let resolution = await XCUIBridgeResolver.resolve(
            preferred: driverOptions.port, repoRoot: try? RepoRoot.find(), autoStart: false,
            logger: { message in
                FileHandle.standardError.write(Data(("[live serve] " + message + "\n").utf8))
            })
        return (BridgeClient(port: resolution.endpoint.port, host: resolution.endpoint.host),
                resolution.endpoint.port)
    }

    /// platform=ios かつ --udid 指定時のみ自動起動を有効化する。RepoRoot.find() の失敗は
    /// serve 自体を止めず自動起動なしで続行する(--udid 未指定時と同じ扱いに落とす)
    private func makeAutoStarter(port: UInt16) -> LiveBridgeAutoStarter? {
        guard driverOptions.platform == "ios", let udid else { return nil }
        do {
            let repoRoot = try RepoRoot.find()
            return LiveBridgeAutoStarter(repoRoot: repoRoot, udid: udid, port: port)
        } catch {
            logStderr("Repository root not found — disabling bridge auto-start: " +
                error.localizedDescription)
            return nil
        }
    }

    /// 1コマンドを処理する: refresh 以外はまずアクションを実行して actionResult を出し、
    /// 続けて(操作の成否を問わず)観測イベントを出す。refresh は観測イベントのみ
    private func handle(
        command: ApiLiveServeCommand, driver: AppDriver, starter: LiveBridgeAutoStarter?
    ) async {
        if command.cmd == "frame" {
            await emitFrame(driver: driver, starter: starter)
            return
        }
        if command.cmd != "refresh" {
            do {
                try await perform(command: command, driver: driver)
                emitLine(ApiLiveActionResultEvent(ok: true, error: nil))
            } catch {
                let message = await annotated(error, starter: starter, triggering: true)
                emitLine(ApiLiveActionResultEvent(ok: false, error: message))
            }
        }
        await emitObservation(driver: driver, starter: starter)
    }

    /// error が DriverError.bridgeConnectionRefused のときだけ starter のサフィックスを連結する
    /// (bridgeUnreachable やタイムアウトでは連結しない=生きているブリッジとの二重起動を防ぐ)。
    /// triggering: true なら noteConnectionRefused(起動トリガーあり)、false なら
    /// statusSuffix(起動トリガーなし。emitFrame は受動的観測のため)
    private func annotated(
        _ error: Error, starter: LiveBridgeAutoStarter?, triggering: Bool
    ) async -> String {
        var message = error.localizedDescription
        guard let starter, case DriverError.bridgeConnectionRefused = error else { return message }
        message += triggering ? await starter.noteConnectionRefused() : await starter.statusSuffix()
        return message
    }

    /// コマンドに応じたドライバ操作を実行する。引数不足・未知の cmd は ServeCommandError を投げる
    /// (呼び出し元 handle が actionResult の ok:false として拾う)
    private func perform(command: ApiLiveServeCommand, driver: AppDriver) async throws {
        switch command.cmd {
        case "tap":
            if let ref = command.ref {
                try await driver.tap(ref: ref)
            } else if let x = command.x, let y = command.y {
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
            try await driver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: command.press ?? 0.05,
                                  durationSeconds: command.duration ?? 0.3)
        case "press":
            guard let x = command.x, let y = command.y, let duration = command.duration else {
                throw ServeCommandError.invalidArguments("press requires x/y/duration")
            }
            try await driver.press(x: x, y: y, duration: duration)
        case "launch":
            guard let bundle = command.bundle else {
                throw ServeCommandError.invalidArguments("launch requires bundle")
            }
            try await driver.launch(bundleID: bundle)
        case "activate":
            guard let bundle = command.bundle else {
                throw ServeCommandError.invalidArguments("activate requires bundle")
            }
            try await driver.activate(bundleID: bundle)
        case "appSwitcher":
            try await driver.openAppSwitcher()
        case "home":
            try await driver.home()
        case "back":
            try await driver.back()
        case "terminate":
            try await driver.terminate()
        case "install":
            guard let path = command.path else {
                throw ServeCommandError.invalidArguments("install requires path")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw ServeCommandError.invalidArguments("package file not found: \(path)")
            }
            // 中身が同じなら入れ直さない(run 側 BridgeProvisioner と同じ規律)。
            // 再インストールはアプリを終了させ、記録開始のたびに状態が消えるため
            if driverOptions.platform == "ios", let udid,
               let bundleID = Self.bundleID(inAppBundle: path),
               InstalledAppCheck.simulatorAppIsCurrent(
                   udid: udid, bundleID: bundleID, appPath: path) {
                logStderr("→ install: skipped (contents identical to the installed app): \(bundleID)")
                return
            }
            try await driver.install(packagePath: path)
            if driverOptions.platform == "ios", let udid,
               let bundleID = Self.bundleID(inAppBundle: path) {
                InstalledAppCheck.recordInstalled(udid: udid, bundleID: bundleID, appPath: path)
            }
        default:
            throw ServeCommandError.invalidArguments("unknown cmd: \(command.cmd)")
        }
    }

    /// スクリーンショット(ダウンスケール済み JPEG)とアクセシビリティツリーを観測イベントとして出す
    /// (ApiMonitorCommand.swift の MonitorImage を共有利用する)。refresh(ユーザーの「更新」
    /// ボタン)はこの経路しか通らないため、ここでの自動起動トリガーは必須
    private func emitObservation(driver: AppDriver, starter: LiveBridgeAutoStarter?) async {
        do {
            let png = try await driver.screenshot()
            let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
            let snap = try await snapshotWithSessionFallback(driver: driver)
            let elements = snap.elements.map {
                ApiLiveElement(ref: $0.ref, type: $0.type, label: $0.label,
                               identifier: $0.identifier, value: $0.value, frame: $0.frame)
            }
            emitLine(ApiLiveSnapshotEvent(
                ok: true, error: nil,
                platform: driverOptions.platform,
                screen: ApiLiveScreenSize(width: snap.screen.width, height: snap.screen.height),
                image: jpeg.data.base64EncodedString(), elements: elements))
        } catch {
            let message = await annotated(error, starter: starter, triggering: true)
            emitLine(ApiLiveSnapshotEvent(
                ok: false, error: message,
                platform: nil, screen: nil, image: nil, elements: nil))
        }
    }

    /// スクリーンショットのみの観測イベント(kind:"frame")。自動画面更新用に AX スナップショット
    /// を省いて軽量化している(要素一覧は更新されない)。自動フレームは受動的観測のため起動は
    /// トリガーせず、既知の状態(starting/failed)があれば付記するだけ
    private func emitFrame(driver: AppDriver, starter: LiveBridgeAutoStarter?) async {
        do {
            let png = try await driver.screenshot()
            let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
            emitLine(ApiLiveFrameEvent(ok: true, error: nil, image: jpeg.data.base64EncodedString()))
        } catch {
            let message = await annotated(error, starter: starter, triggering: false)
            emitLine(ApiLiveFrameEvent(ok: false, error: message, image: nil))
        }
    }

    /// xcuitest ブリッジはセッション未作成だと /snapshot が 409 を返す(ライブ操作はデバイス選択
    /// 直後などアプリ未起動のまま観測しうる)。409 のときだけ springboard 参照セッション
    /// (起動せず・非破壊。SystemUIDriver.swift と同じ経路)を張って1回だけ再試行する。
    /// 409 以外(タイムアウト等)で再試行しないのは、生きている既存アプリセッションを
    /// springboard で上書きしないため。
    private func snapshotWithSessionFallback(driver: AppDriver) async throws -> SnapshotResponse {
        do {
            return try await driver.snapshot()
        } catch DriverError.badResponse(let status, _) where status == 409 {
            try await driver.launch(bundleID: "com.apple.springboard")
            return try await driver.snapshot()
        }
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[live serve] " + message + "\n").utf8))
    }
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
    print(line)
}

// MARK: - stdin コマンド

/// stdin から受け取る1コマンド分(NDJSON 1行)。cmd 以外は全コマンド共通のオプショナルとし、
/// 必須引数の欠落は perform(command:driver:) がコマンド種別毎に判定する(JSON自体が壊れている
/// 行だけを無視し、フィールド欠落は actionResult の ok:false として1件だけ失敗させるため)
private struct ApiLiveServeCommand: Decodable {
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
}

// MARK: - JSON 出力(イベント)

/// actionResult イベント(refresh 以外の全コマンド共通)
private struct ApiLiveActionResultEvent: Encodable {
    let kind = "actionResult"
    let ok: Bool
    let error: String?

    private enum CodingKeys: String, CodingKey { case kind, ok, error }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
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
/// それらが null になる
private struct ApiLiveSnapshotEvent: Encodable {
    let kind = "snapshot"
    let ok: Bool
    let error: String?
    let platform: String?
    let screen: ApiLiveScreenSize?
    let image: String?
    let elements: [ApiLiveElement]?

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error, platform, screen, image, elements
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
    }
}

/// frame(画像のみ観測)イベント。ok:true 時は image が必ず埋まる
private struct ApiLiveFrameEvent: Encodable {
    let kind = "frame"
    let ok: Bool
    let error: String?
    let image: String?

    private enum CodingKeys: String, CodingKey { case kind, ok, error, image }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(image, forKey: .image)
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
