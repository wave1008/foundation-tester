// 2026-08-14: `profile:` 経路の接続断からの回復が一度も動かなかった欠陥。
//
// `connectionLostHint` は表示ラベル(`connections[key]`)の接頭辞("port"/"serial ")で
// iOS/Android のどちらの回復ハンドラへ回すかを決めていたが、profile 経由のラベルは
// "<device name> port <値>" / "<device name> serial <値>" で、どちらの接頭辞にも一致しない。
// 結果、profile 経由のセッションは `forgetConnection` が一度も走らず、死んだブリッジへ
// 永久に再ダイヤルし続けていた(実機の陽性対照で確認)。
//
// 実機ではもう1つ穴があった: iOS の材料 `connectedPorts[key]` は profile 経路で
// `probePort`(実機では常に nil)をそのまま記録しており、フォールバック
// (`probePort ?? provisioned.port`)が無かったため、経路を直しても実機では
// 材料そのものが空で iOS 経路にすら入れなかった。
//
// 直したのは記録先の一本化: iOS は `connectedPorts`、Android は新設した
// `connectedAndroidSerials` を判別材料にし、`androidConnectionLostHint` はそこから serial を
// 受け取る(文字列切り出しをやめる)。`forgetConnection` の Android 分岐も同じ理由で
// 表示ラベルの切り出しをやめた(同型の欠陥が forgetConnection にも独立に存在した)。

import XCTest
@testable import fleetest_mcp

final class MCPAuditFixes20260814ConnectionRecoveryTests: XCTestCase {

    private static func dispatchSource() throws -> String {
        try MCPServerSourceText.combined()
    }

    private static func driverSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift"), encoding: .utf8)
    }

    // MARK: - 入口(connectionLostHint)がラベルではなく記録で振り分けること

    /// **ラベルの接頭辞判定に戻っていないこと**。`connectedPorts`/`connectedAndroidSerials`
    /// のどちらも見ない実装(旧 `connection.hasPrefix(...)`)へ戻すと、profile 経由のラベルは
    /// どちらの回復ハンドラにも入らなくなる
    func testConnectionLostHintRoutesByRecordedMaterialNotLabelPrefix() throws {
        let source = try Self.dispatchSource()
        let start = try XCTUnwrap(source.range(of: "func connectionLostHint("),
                                  "connectionLostHint が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    func iosConnectionLostHint("),
                                "connectionLostHint の終端(次の関数)が見つからない")
        let body = String(tail[..<end.lowerBound])

        XCTAssertTrue(body.contains("connectedPorts[key] != nil"),
                     "iOS 経路の判別が connectedPorts の記録を見ていない"
                     + "(profile 経由のラベルは \"port\" では始まらないので接頭辞判定に戻すと壊れる)")
        XCTAssertTrue(body.contains("connectedAndroidSerials[key]"),
                     "Android 経路の判別が connectedAndroidSerials の記録を見ていない"
                     + "(profile 経由のラベルは \"serial \" では始まらないので接頭辞判定に戻すと壊れる)")
        XCTAssertFalse(body.contains("connection.hasPrefix"),
                       "表示ラベルの接頭辞で経路を振り分けている — profile 経由のラベルは"
                       + " \"<device name> port/serial <値>\" でどちらの接頭辞にも一致しない")
    }

    /// **androidConnectionLostHint がもう表示ラベルを切り出さないこと**。serial は呼び手
    /// (connectionLostHint)が `connectedAndroidSerials` から渡す引数になった
    func testAndroidConnectionLostHintNoLongerParsesTheDisplayLabel() throws {
        let source = try Self.dispatchSource()
        let start = try XCTUnwrap(source.range(of: "func androidConnectionLostHint("),
                                  "androidConnectionLostHint が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(
            tail.range(of: "\n    /// probe(`adb devices` 相当の一覧)から見てこの serial は消えたか"),
            "androidConnectionLostHint の終端(次のコメント)が見つからない")
        let signatureAndBody = "func androidConnectionLostHint(" + String(tail[..<end.lowerBound])

        XCTAssertTrue(signatureAndBody.contains("serial: String"),
                     "androidConnectionLostHint が serial を引数で受け取っていない")
        XCTAssertFalse(signatureAndBody.contains("dropFirst(\"serial \""),
                       "表示ラベルから serial を切り出している — profile 経由のラベルは"
                       + " \"serial \" で始まらないので切り出しが空振りする")
        XCTAssertFalse(signatureAndBody.contains("hasPrefix(\"serial \")"),
                       "表示ラベルの接頭辞チェックが残っている")
    }

    // MARK: - 記録側: profile 経路が iOS/Android それぞれの材料を書くこと

    /// **ソース走査**: `driver()` の profile 分岐が、connectionLostHint の判別材料
    /// (`connectedPorts`/`connectedAndroidSerials`)を iOS/Android それぞれで書くこと。
    /// この分岐は makeDriver 注入より手前で短絡されるため call() 越しには踏めない
    /// (MCPAuditFixes20260813PhysicalDeviceTests.testProfileBranchOfDriverCallsTheRecorder と
    /// 同じ理由)。**OS ごとに1本ずつ要求する** —— 「どこかに1回あるか」だと片方の OS だけ
    /// 外す変異を素通しする(同テストファイルの実績に倣う)
    func testProfileBranchRecordsConnectionLostRecoveryMaterialForBothPlatforms() throws {
        let source = try Self.driverSource()
        let marker = "if let profileName = args[\"profile\"] as? String {"
        let start = try XCTUnwrap(source.range(of: marker), "profile 分岐の開始が見つからない")
        let tail = source[start.upperBound...]
        let returnCreated = try XCTUnwrap(tail.range(of: "return created"),
                                          "profile 分岐の return が見つからない")
        let body = String(tail[..<returnCreated.lowerBound])

        XCTAssertTrue(body.contains("connectedPorts[key] = probePort ?? provisioned.port"),
                     "profile 分岐の iOS 側が connectedPorts を記録していない、"
                     + "またはフォールバックが無い(実機は probePort が常に nil)")
        XCTAssertTrue(body.contains("connectedAndroidSerials[key] = serial"),
                     "profile 分岐の Android 側が connectedAndroidSerials を記録していない"
                     + "(記録しないと profile 経由の Android は connectionLostHint の入口で"
                     + "一度も Android 経路に入らず、回復が永久に走らない)")
    }

    /// **実機で probePort が nil になっても材料が nil にならないこと**。`probePort` は実機では
    /// 常に nil(loopback 経由ではないため。`iosDriver` の doc 参照)なので、フォールバックが
    /// 無いと実機の profile 呼び出しは connectionLostHint の入口で iOS 経路にすら入れない
    func testProfileBranchFallsBackToProvisionedPortWhenProbePortIsNil() throws {
        let source = try Self.driverSource()
        XCTAssertTrue(source.contains("connectedPorts[key] = probePort ?? provisioned.port"),
                     "probePort が nil の実機で connectedPorts が空になる"
                     + "(?? provisioned.port のフォールバックが無い)")
    }

    /// **ソース走査**: profile 無しの直接指定 Android 経路(`case "android":`)も
    /// connectedAndroidSerials を記録すること。2経路のうち片方だけ直しても、直接指定した
    /// Android 機は接続断から回復しないまま残る
    func testDirectAndroidBranchAlsoRecordsConnectionLostRecoveryMaterial() throws {
        let source = try Self.driverSource()
        let start = try XCTUnwrap(source.range(of: "case \"android\":"),
                                  "直接指定の Android 分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n        default:"),
                                "Android 分岐の終端(default:)が見つからない")
        let body = String(tail[..<end.lowerBound])
        XCTAssertTrue(body.contains("connectedAndroidSerials[key] = serial"),
                     "直接指定の Android 経路が connectedAndroidSerials を記録していない")
    }

    // MARK: - 後始末: forgetDeviceState/forgetConnection が新しい記録も忘れること

    /// `forgetDeviceState` は engineKey で引く記憶を全部捨てる契約(DeviceStateInvalidationTests
    /// 参照)。新設した `connectedAndroidSerials` を足し忘れていないかを直接確かめる
    /// (`testEveryEngineKeyedMemoIsAccountedForHere` の汎用走査と、この具体的な instance
    /// レベルの確認を両方持つ)
    func testForgetDeviceStatePurgesTheAndroidSerialRecord() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "profile::android-device:android"
        server.connectedAndroidSerials[key] = "emulator-5554"

        server.forgetDeviceState(key)

        XCTAssertNil(server.connectedAndroidSerials[key],
                     "死んだ serial の記録が forgetDeviceState を通しても残っている")
    }

    /// **回帰確認(実測した実害の再現)**: profile 経由のラベルを持つ Android 接続で、
    /// `forgetConnection` が(表示ラベルの切り出しではなく)`connectedAndroidSerials` の記録を
    /// 見て `lastExplicitAndroidSerial` を正しく消せること
    func testForgetConnectionClearsAndroidMemoryFromAProfileStyleLabel() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "profile::android-device:android"
        server.connections[key] = "Pixel 9(Android 15)-01 serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.seenExplicitAndroidSerials = ["emulator-5554"]

        server.forgetConnection(key)

        XCTAssertNil(server.lastExplicitAndroidSerial,
                     "profile 経由のラベルでは死んだ serial への記憶が消えない"
                     + "(実測した実害: profile: の呼び出しが死んだブリッジへ再ダイヤルされ続ける)")
        XCTAssertTrue(server.seenExplicitAndroidSerials.isEmpty)
        XCTAssertNil(server.connectedAndroidSerials[key])
    }
}
