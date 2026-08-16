// 委譲した WebView が中身を出さないまま待ちを使い切ったとき、**木がそれを名乗る**こと。
//
// ここが黙ると、空の木を受け取った StepExecutor には「AX がまだ公開されていない」のか
// 「本当に空のページ」なのか判る材料が無く、否定アサーションが必ず通る(誤った成功)。
// 待ちの上限は Simulator の実測 2.3s に対する余裕でしかなく、hybrid は実機でも動くので
// **尽きること自体が想定内**。
//
// このテストは待ちの上限(5s)をそのまま払う = **意図的に遅い**。上限を注入口にすると
// 「本番の値で尽きたときの挙動」を確かめられなくなるので、実時間で確かめる側に倒している。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 中身の無い WebView 画面を返し続けるドライバ(primary/delegated 兼用)
private final class BlankWebViewDriver: AppDriver {
    private(set) var snapshots = 0

    func snapshot() async throws -> SnapshotResponse {
        snapshots += 1
        return SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1)],
            truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// Web コンテンツが最初から入っている画面(委譲するが待たない)
private final class RenderedWebViewDriver: AppDriver {
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1),
                ElementInfo(ref: 2, type: "link", identifier: nil, label: "ホーム", value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 10, y: 20, width: 100, height: 20), depth: 2),
            ],
            truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class EmptyWebViewPathTests: XCTestCase {

    /// 待ちを使い切った木は `delegated-empty` を名乗る(黙って `delegated` を返さない)
    func testExhaustedWaitIsDeclaredOnTheTree() async throws {
        let driver = WebViewDelegatingDriver(primary: BlankWebViewDriver(),
                                             delegated: BlankWebViewDriver())
        let snapshot = try await driver.snapshot()
        XCTAssertEqual(snapshot.webViewPath, WebViewPath.delegatedEmpty,
                       "空のまま待ちが尽きたのに黙って返した")
        XCTAssertEqual(driver.lastActionNote?.contains("no content"), true,
                       "\(driver.lastActionNote ?? "-")")
    }

    /// 逆方向: 中身が出ていれば従来どおり `delegated`(毎回名乗ると意味が薄れる)
    func testARenderedWebViewKeepsTheDelegatedPath() async throws {
        let driver = WebViewDelegatingDriver(primary: BlankWebViewDriver(),
                                             delegated: RenderedWebViewDriver())
        let snapshot = try await driver.snapshot()
        XCTAssertEqual(snapshot.webViewPath, WebViewPath.delegated)
    }
}
