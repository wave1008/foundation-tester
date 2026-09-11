// 物理 Android の画面が消灯したままだと、`ft_snapshot` は常時表示の木を返し `ft_tap` は `done` を
// 返す(消灯に一言も触れない)。そこで run 経路(`ProfileWorkerFactory.preparePhysicalAndroidDevices` → `AndroidPhysicalDevice.
// prepareForRun`)と同じ処理を、`driver(_:)` の唯一の呼び口(全ツール共通)から
// このセッションでその機へ初めて触れたときに1回だけ呼ぶ(`prepareAndroidDeviceIfNeeded`)。
//
// **`AndroidDriver` は FTAndroid 依存で FakeDriver からは模せない**ので(実体は adb を叩く)、
// 「本物の Android + 未起動」の分岐は実機無しでは動的に確かめられない。ここで確かめるのは
// (1) 差し替えドライバ(テスト・FakeDriver)では何もしない(実 adb を1本も呼ばない)
// (2) Android でないドライバでは何もしない
// の2つと、配線(ソース走査。MCPRotateSettleTests/MCPProfilePlatformTests と同じ規律)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPPhysicalAndroidWakeTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    /// FakeDriver は AndroidDriver ではないので、物理判定に届く前に何もしない
    func testDoesNothingForANonAndroidDriver() async throws {
        server.connectedAndroidSerials["k"] = "192.168.1.5:5555"
        await server.prepareAndroidDeviceIfNeeded(driver, args: ["profile": "k"])
        XCTAssertTrue(server.preparedPhysicalAndroid.isEmpty,
                      "Android でないドライバなのに準備済みにしてしまった")
    }

    /// **差し替えドライバ(テスト)では実 adb を1本も呼ばない**: FakeDriver 経由の通常のツール
    /// 呼び出し列(ft_snapshot → ft_launch → ft_tap)がタイムアウトも実デバイス待ちも無く
    /// 完了することが、このゲートがテスト環境で正しく無効化されている証拠になる
    func testOrdinaryToolCallsWithAFakeDriverCompleteWithoutTouchingAndroidPreparation() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        XCTAssertTrue(server.preparedPhysicalAndroid.isEmpty,
                      "テスト用の差し替えドライバなのに物理 Android の準備を記録してしまった")
    }

    /// **配線の確認**(`AndroidDriver` を FakeDriver から模せないので、ソース走査で守る。
    /// MCPProfilePlatformTests / MCPRotateSettleTests と同じ規律): `driver(_:)` が
    /// `resolveDriver` の直後に `prepareAndroidDeviceIfNeeded` を呼び、後者が
    /// 差し替えドライバ(`makeDriver == nil`)・物理判定(`DevicePicker.
    /// isPhysicalAndroidSerial`)・一度きり(`preparedPhysicalAndroid`)の3つを守っていること
    func testWakeGateIsWiredIntoTheSingleDriverEntryPoint() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("let resolved = try await resolveDriver(args)"), "唯一の呼び口")
        XCTAssertTrue(code.contains("await prepareAndroidDeviceIfNeeded(resolved, args: args)"),
                      "driver(_:) が起こす処理を呼んでいない")
        XCTAssertTrue(code.contains("guard resolved is AndroidDriver, makeDriver == nil else { return }"),
                      "Android 限定・テスト無効化の門")
        XCTAssertTrue(code.contains("DevicePicker.isPhysicalAndroidSerial(serial)"),
                      "物理端末だけに絞る判定")
        XCTAssertTrue(code.contains("preparedPhysicalAndroid.insert(key)"), "一度きりの記録")
        XCTAssertTrue(code.contains("AndroidPhysicalDevice.prepareForRun(serial: serial, log: Self.logStderr)"),
                      "run 経路と同じ関数を呼んでいること")
    }
}
