import FTCore
import XCTest
@testable import FTBridgeClient

/// iOS 実機まわりの純粋ロジック(devicectl JSON のパース・ランナー宣言の読み取り・
/// endpoint の永続化)。実機の接続を要する経路はここでは検証しない
final class IOSPhysicalDeviceTests: XCTestCase {

    // MARK: - devicectl JSON のパース

    /// properties 辞書(現行形式)。deprecated 側が無くても読めること
    func testParsePhysicalDeviceFromPropertiesDictionary() throws {
        let entry: [String: Any] = [
            "identifier": "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B",
            "properties": [
                // 実機の reality は nil。marketingName も欠けることがある(2026-07-25 実機実測)
                "hardware": ["platform": "iOS", "udid": "00008130-000A1B2C3D4E5678"],
                "state": ["name": "私の iPhone", "bootState": "booted"],
                "software": ["osVersionNumber": ["stringValue": "18.5"]],
                "connection": ["state": "connected", "transportType": "wired"],
            ],
        ]
        let device = try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(entry))
        XCTAssertEqual(device.udid, "00008130-000A1B2C3D4E5678",
                       "xcodebuild -destination が受け付けるのは hardware.udid だけ")
        XCTAssertEqual(device.deviceCtlIdentifier, "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B")
        XCTAssertEqual(device.name, "私の iPhone")
        XCTAssertEqual(device.os, "iOS 18.5")
        XCTAssertTrue(device.connected)
        XCTAssertEqual(device.transport, "wired")
    }

    /// シミュレータは同じ一覧に混ざる。reality=simulated を必ず捨てること
    func testParseDropsSimulatedEntries() {
        let entry: [String: Any] = [
            "identifier": "7202E9B3-962C-41A7-B6E7-FC15C6053DD8",
            "properties": [
                "hardware": ["platform": "iOS", "reality": "simulated"],
                "state": ["name": "iPhone 17 Pro"],
            ],
        ]
        XCTAssertNil(IOSPhysicalDeviceCatalog.parse(entry))
    }

    /// reality は physical/simulated/virtual の三値だが実機はキーごと省略する。
    /// 将来 Apple が "physical" を出すようになっても拾えること
    func testParseAcceptsExplicitPhysicalReality() throws {
        let entry: [String: Any] = [
            "identifier": "ID",
            "properties": [
                "hardware": ["platform": "iOS", "reality": "physical", "udid": "00008130-BBBB"],
                "state": ["name": "iPhone"],
            ],
        ]
        XCTAssertEqual(try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(entry)).udid, "00008130-BBBB")
    }

    func testParseDropsNonIOSPlatforms() {
        let entry: [String: Any] = [
            "identifier": "X",
            "properties": ["hardware": ["platform": "watchOS", "udid": "X"]],
        ]
        XCTAssertNil(IOSPhysicalDeviceCatalog.parse(entry))
    }

    /// 旧 Xcode 向けフォールバック: deprecated な hardwareProperties/deviceProperties だけの形
    func testParseFallsBackToDeprecatedFields() throws {
        let entry: [String: Any] = [
            "identifier": "00008130-AAAA",
            "hardwareProperties": ["platform": "iOS", "udid": "00008130-AAAA",
                                   "marketingName": "iPhone 14"],
            "deviceProperties": ["name": "旧形式 iPhone", "osVersionNumber": "17.5"],
            "connectionProperties": ["tunnelState": "connected", "transportType": "localNetwork"],
        ]
        let device = try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(entry))
        XCTAssertEqual(device.name, "旧形式 iPhone")
        XCTAssertEqual(device.os, "iOS 17.5")
        XCTAssertTrue(device.connected, "deprecated 側は tunnelState を接続状態として読む")
        XCTAssertEqual(device.transport, "localNetwork")
    }

    /// USB 接続中の実機でも connection.state は "disconnected" のままだった(2026-07-25 実機実測)。
    /// pairingState/bootState の肯定シグナルで到達可能と判定できること
    func testParseTreatsPairedButDisconnectedDeviceAsAvailable() throws {
        let entry: [String: Any] = [
            "identifier": "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B",
            "properties": [
                "hardware": ["platform": "iOS", "udid": "00008130-001819863E60001C"],
                "state": ["name": "iPhone wave", "bootState": "booted"],
                "connection": ["state": "disconnected", "pairingState": "paired",
                               "transportType": "wired"],
            ],
        ]
        let device = try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(entry))
        XCTAssertTrue(device.connected,
                      "connection.state は当てにならない(未接続機はそもそも一覧に出ない)")
    }

    /// devicectl の Identifier 列を profile に書いてしまっても解決できること
    func testResolveAcceptsDeviceCtlIdentifier() throws {
        let devices = [IOSPhysicalDeviceInfo(udid: "00008130-AAAA", name: "iPhone", os: "iOS 26.5",
                                             connected: true, transport: "wired",
                                             deviceCtlIdentifier: "2DBFD3DF-21FE")]
        let spec = DeviceSpec(name: "実機", kind: .physical, udid: "2DBFD3DF-21FE")
        let resolved = try IOSPhysicalDeviceCatalog.resolve(spec: spec, in: devices)
        XCTAssertEqual(resolved.udid, "00008130-AAAA", "解決後は必ず hardware.udid を返す")
    }

    func testResolveRejectsDisconnectedDevice() {
        let devices = [IOSPhysicalDeviceInfo(udid: "U1", name: "iPhone", os: "iOS 18.5",
                                             connected: false, transport: "wired")]
        let spec = DeviceSpec(name: "実機", kind: .physical, udid: "U1")
        XCTAssertThrowsError(try IOSPhysicalDeviceCatalog.resolve(spec: spec, in: devices)) { error in
            guard case IOSPhysicalDeviceCatalogError.notConnected = error else {
                return XCTFail("notConnected のはず: \(error)")
            }
        }
    }

    func testResolveRejectsUnknownUDID() {
        let devices = [IOSPhysicalDeviceInfo(udid: "U1", name: "iPhone", os: "iOS 18.5",
                                             connected: true, transport: "wired")]
        let spec = DeviceSpec(name: "実機", kind: .physical, udid: "U2")
        XCTAssertThrowsError(try IOSPhysicalDeviceCatalog.resolve(spec: spec, in: devices)) { error in
            guard case IOSPhysicalDeviceCatalogError.notFound = error else {
                return XCTFail("notFound のはず: \(error)")
            }
        }
    }

    // MARK: - LAN 宣言の読み取り(ランナーのテストログ)

    func testAnnouncedHostPicksMatchingPort() {
        let log = """
        Test Suite 'All tests' started
        FT_BRIDGE_ADDR=192.168.1.23:8123
        FT_BRIDGE_ADDR=192.168.1.99:8124
        """
        XCTAssertEqual(IOSDeviceTransport.announcedHost(inLog: log, port: 8124), "192.168.1.99")
    }

    /// ランナーの再起動でログに複数行残る。最後(=最新の起動)を採用する
    func testAnnouncedHostPrefersLastAnnouncementForSamePort() {
        let log = """
        FT_BRIDGE_ADDR=192.168.1.23:8123
        FT_BRIDGE_ADDR=192.168.1.55:8123
        """
        XCTAssertEqual(IOSDeviceTransport.announcedHost(inLog: log, port: 8123), "192.168.1.55")
    }

    func testAnnouncedHostReturnsNilWhenAbsent() {
        XCTAssertNil(IOSDeviceTransport.announcedHost(inLog: "bindFailed(48)\n", port: 8123))
    }

    /// xcodebuild のテストログは CRLF。\r が残るとポート照合が外れて 180 秒待って失敗する
    /// (2026-07-25 の実害。\n 固定のフィクスチャでは再現しなかった)
    func testAnnouncedHostHandlesCRLFLog() {
        let log = "swizzled waitForQuiescence:\r\nFT_BRIDGE_ADDR=192.168.20.5:8201\r\n[ftester] ok\r\n"
        XCTAssertEqual(IOSDeviceTransport.announcedHost(inLog: log, port: 8201), "192.168.20.5")
    }

    // MARK: - ランナー起動失敗の早期検知(180 秒待たない)

    /// 実機の初回で必ず踏む手動手順。汎用メッセージではなく手順を名指しすること
    func testRunnerFailureReasonNamesUntrustedCertificate() throws {
        let log = """
        Testing failed:
        \tThe application could not be launched because the Developer App Certificate is not trusted.
        ** TEST EXECUTE FAILED **
        """
        let reason = try XCTUnwrap(IOSDeviceTransport.runnerFailureReason(inLog: log))
        XCTAssertTrue(reason.contains("VPN & Device Management"), reason)
    }

    /// 起動途中のログを失敗と誤認しないこと(誤検知したら正常な起動を殺す)
    func testRunnerFailureReasonIsNilWhileStarting() {
        XCTAssertNil(IOSDeviceTransport.runnerFailureReason(
            inLog: "Test Suite 'All tests' started\nTesting started\n"))
    }

    /// 理由が既知パターンでなければ xcodebuild の行をそのまま見せる(推測を書かない)。
    /// ログは CRLF なので分割も CRLF で確認する
    func testRunnerFailureReasonFallsBackToLogLine() throws {
        let log = "** TEST EXECUTE FAILED **\r\n"
            + "\terror: Unable to find a destination matching the provided destination specifier\r\n"
        let reason = try XCTUnwrap(IOSDeviceTransport.runnerFailureReason(inLog: log))
        XCTAssertEqual(reason,
                       "error: Unable to find a destination matching the provided destination specifier",
                       "CRLF ログでも 1 行だけを抜き出せること")
    }

    /// 端末ロックは「失敗」ではなく「進まない」条件。throw せず理由として拾えること
    func testBlockingConditionDetectsLockedDevice() throws {
        let log = "Error Domain=com.apple.dt.deviceprep Code=-3 \"Unlock iPhone wave to Continue\"\r\n"
        XCTAssertNil(IOSDeviceTransport.runnerFailureReason(inLog: log),
                     "ロックは TEST EXECUTE FAILED ではないので失敗扱いにしない")
        let blocker = try XCTUnwrap(IOSDeviceTransport.blockingCondition(inLog: log))
        XCTAssertTrue(blocker.contains("Unlock the device"), blocker)
    }

    // MARK: - USB トンネル(iproxy)

    /// PID 再利用で無関係プロセスを「トンネル生存」と誤認しないこと
    /// (誤認すると転送されていないポートへ繋ぎに行って接続拒否になる)
    func testIproxyRunningRejectsUnrelatedProcess() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-iproxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = IOSDeviceTransport.pidURL(hostPort: 8123, repoRoot: root)
        try FileManager.default.createDirectory(
            at: pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 自プロセス(= iproxy ではない)の pid を書く。生存はするがコマンド名が違う
        try String(ProcessInfo.processInfo.processIdentifier)
            .write(to: pidURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(IOSDeviceTransport.isIproxyRunning(hostPort: 8123, repoRoot: root),
                       "生存確認だけでなくコマンド名まで見ること")

        // 存在しない pid
        try "999999".write(to: pidURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(IOSDeviceTransport.isIproxyRunning(hostPort: 8123, repoRoot: root))
    }

    /// 未インストール環境では usb を選ばない(選ぶと iproxyMissing で必ず失敗する)
    func testTransportKindFallsBackToLanWithoutIproxy() {
        XCTAssertEqual(IOSDeviceTransport.kind(environment: ["FT_IOS_DEVICE_TRANSPORT": "lan"]), .lan)
        XCTAssertEqual(IOSDeviceTransport.kind(environment: ["FT_IOS_DEVICE_TRANSPORT": "usb"]), .usb)
        // 環境変数なしのときは iproxy の有無で決まる(このマシンの状態に依存するので存在確認と一致を見る)
        let expected: IOSDeviceTransportKind = IOSDeviceTransport.iproxyPath() == nil ? .lan : .usb
        XCTAssertEqual(IOSDeviceTransport.kind(environment: [:]), expected)
    }

    /// WiFi 接続だけの端末に usb を選ぶと iproxy がトンネルを張れず、原因不明のまま
    /// 180 秒タイムアウトする(2026-07-25 に実際に踏んだ)
    func testTransportKindPrefersLanForNonWiredDevice() {
        XCTAssertEqual(IOSDeviceTransport.kind(environment: [:], wired: false), .lan,
                       "USB 接続でない端末には usb を選ばない")
        // 明示指定は尊重する(切り分け用の殺しスイッチを wired 判定で潰さない)
        XCTAssertEqual(
            IOSDeviceTransport.kind(environment: ["FT_IOS_DEVICE_TRANSPORT": "usb"], wired: false),
            .usb)
    }

    /// SimulatorCatalog.resolve が transportType を wired として運ぶこと
    /// (ここが落ちると WiFi 接続の実機で usb が選ばれる)
    func testResolveCarriesWiredFlagFromTransportType() throws {
        let wifi = IOSPhysicalDeviceInfo(udid: "00008130-A", name: "iPhone wave", os: "iOS 26.5.2",
                                         connected: true, transport: "localNetwork")
        let usb = IOSPhysicalDeviceInfo(udid: "00008130-B", name: "iPhone wired", os: "iOS 26.5.2",
                                        connected: true, transport: "wired")
        let spec = DeviceSpec(name: "実機", kind: .physical, udid: "00008130-A")
        let resolvedWifi = try IOSPhysicalDeviceCatalog.resolve(spec: spec, in: [wifi, usb])
        XCTAssertEqual(resolvedWifi.transport, "localNetwork")
        XCTAssertFalse(resolvedWifi.transport == "wired", "WiFi 接続を wired と誤判定しないこと")
        let usbSpec = DeviceSpec(name: "実機", kind: .physical, udid: "00008130-B")
        XCTAssertTrue(
            try IOSPhysicalDeviceCatalog.resolve(spec: usbSpec, in: [wifi, usb]).transport == "wired")
    }

    // MARK: - 実機ブリッジの帰属(UDID → ポート)

    /// 端末が起動を拒否した条件は、xcodebuild の終端マーカーを待たずに確定させること。
    /// 実測(2026-07-26)で証明書未信頼のエラーは 20 秒時点でログに出ていたのに、
    /// `** TEST EXECUTE FAILED **` が最後まで出ず 181 秒待たされ、無関係な理由で失敗した
    func testRunnerFailureReasonDetectsUntrustedCertificateWithoutTerminalMarker() {
        let log = """
        2026-07-26 00:00:20.893 xcodebuild[15317:9582357]  IDELaunchReport: Launching \
        FTesterRunnerUITests Finished with error: The application could not be launched \
        because the Developer App Certificate is not trusted.
        Recovery Suggestion: Verify that the Developer App certificate for your account is trusted.
        """
        let reason = IOSDeviceTransport.runnerFailureReason(inLog: log)
        XCTAssertNotNil(reason, "終端マーカーが無くても証明書未信頼は確定させる")
        XCTAssertTrue(reason?.contains("VPN & Device Management") == true, "端末側の手順を名指しすること")
    }

    /// 逆に、理由を特定できないログでマーカー無しに失敗扱いしないこと(誤検知で run を殺さない)
    func testRunnerFailureReasonStaysSilentForOrdinaryLogWithoutTerminalMarker() {
        XCTAssertNil(IOSDeviceTransport.runnerFailureReason(
            inLog: "Test Suite 'All tests' started\nerror: something transient\n"))
    }

    /// 実機は /status の device が機種名で返るため名前照合では紐付かない。
    /// ランナープロセスの起動引数に載る UDID で帰属を決められること
    func testPortsMatchingFindsBridgeByUDIDInProcessArguments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-ports-\(UUID().uuidString)")
        let stateDir = root.appendingPathComponent(".ftester")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 起動引数に UDID を含む生きたプロセス(ランナーの -destination id=<UDID> の代役)
        let udid = "00008130-001819863E60001C"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // **`sh -c "<単一コマンド>"` にしないこと**: sh が exec して自分を置き換えるため
        // ps の command から引数(= UDID)が消える。`;` で 2 コマンドにすると sh が残る
        process.arguments = ["-c", "sleep 20; : -destination platform=iOS,id=\(udid)"]
        try process.run()
        defer { process.terminate() }
        try String(process.processIdentifier).write(
            to: stateDir.appendingPathComponent("bridge-8199.pid"),
            atomically: true, encoding: .utf8)
        // 死んだ pid の stale ファイル(別ポート)。混ざらないこと
        try "999999".write(to: stateDir.appendingPathComponent("bridge-8198.pid"),
                           atomically: true, encoding: .utf8)

        XCTAssertEqual(BridgeLauncher.portsMatching(udid: udid, repoRoot: root), [8199])
        XCTAssertEqual(BridgeLauncher.portsMatching(udid: "00008130-OTHER", repoRoot: root), [],
                       "別 UDID のブリッジを拾わないこと")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateDir.appendingPathComponent("bridge-8198.pid").path),
            "読み取り専用の契約: stale な pid ファイルを消さない(掃除は stopMatching の役割)")
    }

    // MARK: - endpoint の永続化

    func testEndpointRoundTripsThroughFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-endpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        BridgeEndpoint(host: "192.168.1.23", port: 8123).persist(repoRoot: root)
        XCTAssertEqual(BridgeEndpoint.load(port: 8123, repoRoot: root).host, "192.168.1.23")

        // 記録が無いポートはループバック(シミュレータ・Android の既定)
        XCTAssertTrue(BridgeEndpoint.load(port: 8124, repoRoot: root).isLoopback)

        // ループバックの persist は記録を残さない(シミュレータ運用にファイルを増やさない)
        BridgeEndpoint(port: 8123).persist(repoRoot: root)
        XCTAssertTrue(BridgeEndpoint.load(port: 8123, repoRoot: root).isLoopback)
    }

    // MARK: - 実機 udid の記録(.ftester/bridge-<port>.device、欠陥②の前提)

    func testBridgeDeviceRecordRoundTripsThroughFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-device-record-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        BridgeDeviceRecord.persist(udid: "00008130-001819863E60001C", port: 8123, repoRoot: root)
        XCTAssertEqual(BridgeDeviceRecord.load(port: 8123, repoRoot: root),
                       "00008130-001819863E60001C")

        // 記録の無いポートは nil(旧ブリッジ・仮想デバイスの既定。throw しない)
        XCTAssertNil(BridgeDeviceRecord.load(port: 8124, repoRoot: root))

        BridgeDeviceRecord.forget(port: 8123, repoRoot: root)
        XCTAssertNil(BridgeDeviceRecord.load(port: 8123, repoRoot: root))
    }

    // MARK: - destination(実機 UDID の形状推測をしないこと)

    func testDestinationUsesPhysicalPlatformForDevice() {
        let root = URL(fileURLWithPath: "/tmp")
        // 実機 UDID は 25 文字型。形状推測だと name= に化けてサイレント失敗していた
        let device = BridgeLauncher(repoRoot: root, device: "00008130-000A1B2C3D4E5678",
                                    port: 8123, physical: true)
        XCTAssertEqual(device.destination, "platform=iOS,id=00008130-000A1B2C3D4E5678")

        let simulator = BridgeLauncher(repoRoot: root,
                                       device: "6109860E-93CE-47E1-9989-5DCD16186434", port: 8123)
        XCTAssertEqual(simulator.destination,
                       "platform=iOS Simulator,id=6109860E-93CE-47E1-9989-5DCD16186434")
    }

    /// Team ID 未設定のまま実機ビルドに入ると xcodebuild が原因の分かりにくい署名エラーで落ちる。
    /// 手前で止めること(シミュレータは従来どおり署名引数なし)
    func testCodeSigningArgumentsFailFastWithoutTeam() throws {
        let root = URL(fileURLWithPath: "/tmp/ft")
        let emptyConfig = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-cfg-\(UUID().uuidString)/config.json")
        setenv("XDG_CONFIG_HOME", emptyConfig.deletingLastPathComponent()
            .deletingLastPathComponent().path, 1)
        unsetenv("FT_DEVELOPMENT_TEAM")
        defer { unsetenv("XDG_CONFIG_HOME") }

        XCTAssertEqual(try BridgeLauncher(repoRoot: root, device: "U", port: 8123)
            .codeSigningArguments(), [], "シミュレータは署名引数を足さない")
        XCTAssertThrowsError(
            try BridgeLauncher(repoRoot: root, device: "U", port: 8123, physical: true)
                .codeSigningArguments()
        ) { error in
            guard case LauncherError.developmentTeamMissing = error else {
                return XCTFail("developmentTeamMissing のはず: \(error)")
            }
        }
    }

    func testDerivedDataIsSeparatedByDeviceKind() {
        let root = URL(fileURLWithPath: "/tmp/ft")
        let device = BridgeLauncher(repoRoot: root, device: "U", port: 8123, physical: true)
        let simulator = BridgeLauncher(repoRoot: root, device: "U", port: 8123)
        XCTAssertNotEqual(device.derivedDataPath, simulator.derivedDataPath,
                          "混在すると findXCTestRun が iphoneos/iphonesimulator の誤った方を掴む")
    }

    // MARK: - 配線(ソース走査): 実機 udid の記録の寿命をブリッジと揃えること

    /// 記録を書くのは establish・消すのは teardown の各1箇所(BridgeDeviceRecord の契約)。
    /// **書き込みが外れても純粋関数のテストは全部緑のまま**なので、ここで配線を止める
    /// (実機が要るのでテストからは踏めない。欠陥②)
    func testTransportWritesAndForgetsTheUDIDRecord() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/FTBridgeClient/IOSDeviceTransport.swift"),
            encoding: .utf8)
        func body(of function: String, until terminator: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: function), "\(function) が見つからない")
            let tail = source[start.upperBound...]
            let end = try XCTUnwrap(tail.range(of: terminator), "\(function) の終端が見つからない")
            return String(tail[..<end.lowerBound])
        }
        XCTAssertTrue(try body(of: "public static func establish(", until: "return endpoint")
                        .contains("BridgeDeviceRecord.persist"),
                      "establish が udid を記録しない —— 実機ブリッジは udid で指せないままになる")
        XCTAssertTrue(try body(of: "public static func teardown(", until: "\n    }")
                        .contains("BridgeDeviceRecord.forget"),
                      "teardown が記録を消さない —— 死んだブリッジの udid が残る")
    }
}
