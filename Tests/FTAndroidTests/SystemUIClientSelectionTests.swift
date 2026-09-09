// run 開始時に SpringBoard を触る操作(home / 残存アラートの警告)がどのブリッジへ行くかの選別。
//
// **実害 2026-09-09**: `RunWorker.driver` は in-app ブリッジ宛の BridgeClient で、in-app には
// `/home` のルートが無い。hybrid でもそれを撃っていたため homeOnStart が 18 台すべてで 0/N=不発
// だった(しかも「inapp 固定の台だけができない」と誤って説明していた)。宛先の決定は
// `ProfileWorkerFactory.systemUIClient` の1箇所に寄せてある。

import XCTest
@testable import FTBridgeClient
import FTCore
@testable import FTAndroid

final class SystemUIClientSelectionTests: XCTestCase {

    private final class NullDriver: AppDriver, @unchecked Sendable {
        func screenshot() async throws -> Data { Data() }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func terminate() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                   path: FTSwipePath?) async throws {}
    }

    private func worker(platform: String, connection: DriverConnection) -> RunWorker {
        RunWorker(label: "w", platform: platform, driver: NullDriver(), connection: connection)
    }

    /// hybrid(既定の iosInappEngine=true)は in-app と XCUITest の両方を持つ。**XCUITest 側へ行く**
    func testHybridGoesToTheXcuitestBridgeNotTheInappOne() {
        let client = ProfileWorkerFactory.systemUIClient(for: worker(
            platform: "ios",
            connection: DriverConnection(platform: "ios", port: 8131, engine: "hybrid",
                                         udid: "UDID-1", xcuiPort: 8123)))
        XCTAssertEqual(client?.port, 8123, "in-app ブリッジ(8131)には /home のルートが無い")
    }

    /// xcuitest 単独は自分のポート
    func testXcuitestOnlyUsesItsOwnPort() {
        let client = ProfileWorkerFactory.systemUIClient(for: worker(
            platform: "ios",
            connection: DriverConnection(platform: "ios", port: 8123, udid: "UDID-1")))
        XCTAssertEqual(client?.port, 8123)
    }

    /// in-app 単独(XCUITest ブリッジ無し)は撃てない —— **黙って in-app へ落とさない**
    func testInappOnlyHasNoSystemUIClient() {
        let client = ProfileWorkerFactory.systemUIClient(for: worker(
            platform: "ios",
            connection: DriverConnection(platform: "ios", port: 8131, engine: "inapp",
                                         udid: "UDID-1")))
        XCTAssertNil(client)
    }

    /// Android は対象外(home は AndroidDriver が自分で撃てる)
    func testAndroidIsNotATarget() {
        let client = ProfileWorkerFactory.systemUIClient(for: worker(
            platform: "android",
            connection: DriverConnection(platform: "android", port: 8200, serial: "emulator-5554")))
        XCTAssertNil(client)
    }
}
