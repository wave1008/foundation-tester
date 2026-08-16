// `raiseElementLimitOnNextSnapshot` が**実際に最内へ届く**ことを、ソース走査ではなく
// 呼び出しで確かめる(SnapshotCacheBypassForwardingTests は「宣言があるか」しか見られない)。
//
// とくに WebViewDelegatingDriver は、次の1回をどちらの経路で撮るかが**撮ってみるまで
// 決まらない**(mode は直前の snapshot が決めた値)。片方だけに立てると、委譲へ落ちた回で
// 上限が黙って既定へ戻る —— 上限を上げたい画面はまさに WebView なので、そこだけ効かない
// という最悪の形になる。この形は源走査では捕まらない(実際に変異が生き残った)。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 上限指定を受け取った回数だけ数える最小ドライバ
private final class LimitRecordingDriver: AppDriver {
    private(set) var received: [Int?] = []

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 10, height: 10),
                         elements: [], truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func raiseElementLimitOnNextSnapshot(_ max: Int?) { received.append(max) }
}

final class ElementLimitForwardingBehaviourTests: XCTestCase {

    /// **両方へ立てる**: どちらから読まれるか決まっていないため
    func testWebViewDelegatingDriverArmsBothBackends() {
        let primary = LimitRecordingDriver()
        let delegated = LimitRecordingDriver()
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        driver.raiseElementLimitOnNextSnapshot(300)

        XCTAssertEqual(primary.received, [300], "in-app 側へ届いていない")
        XCTAssertEqual(delegated.received, [300],
                       "XCUITest 委譲側へ届いていない —— WebView 画面はこちらで読まれることがあり、"
                       + "その回だけ上限が黙って既定へ戻る")
    }

    /// nil(既定へ戻す)も同じく両方へ届くこと
    func testClearingTheLimitReachesBothBackends() {
        let primary = LimitRecordingDriver()
        let delegated = LimitRecordingDriver()
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        driver.raiseElementLimitOnNextSnapshot(nil)

        XCTAssertEqual(primary.received.count, 1)
        XCTAssertEqual(delegated.received.count, 1)
        XCTAssertNil(primary.received.first ?? 0)
        XCTAssertNil(delegated.received.first ?? 0)
    }
}
