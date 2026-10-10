// swipe / drag の応答の `imageSettleCapped`(ブリッジが画像整定したか)をドライバが写す配線の固定。
// ホストはこれが非 nil のときだけ木の整定を省く(StepExecutor.skippingHostTreeSettle)ので、写し損ねると
// 「整定したのに払う」(遅いだけ)、**古い値が残ると「誰も整定していないのに省く」**(動いている木を掴む)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class GestureImageSettleReportTests: XCTestCase {

    private func client(body: String) throws -> (BridgeClient, RecordingStubServer) {
        let stub = try RecordingStubServer(body: body)
        return (BridgeClient(port: stub.port, interactionTimeout: 5, sessionTimeout: 5), stub)
    }

    func testSwipeCopiesTheBridgeReport() async throws {
        let (capped, s1) = try client(body: #"{"ok":true,"imageSettleCapped":true}"#)
        defer { s1.stop() }
        try await capped.swipe(.up, intent: .gesture, path: nil)
        XCTAssertEqual(capped.lastGestureImageSettleCapped, true)

        let (still, s2) = try client(body: #"{"ok":true,"imageSettleCapped":false}"#)
        defer { s2.stop() }
        try await still.swipe(.up)
        XCTAssertEqual(still.lastGestureImageSettleCapped, false)
    }

    /// 申告の無い応答(in-app・tree モード・旧形)は nil。**同じクライアントで前の swipe / drag の値を持ち越さない**
    func testMissingReportIsNilAndDoesNotCarryOver() async throws {
        let (c, s) = try client(body: #"{"ok":true,"imageSettleCapped":false}"#)
        defer { s.stop() }
        try await c.swipe(.up)
        XCTAssertEqual(c.lastGestureImageSettleCapped, false)
        s.setBody(#"{"ok":true}"#)
        try await c.swipe(.up)
        XCTAssertNil(c.lastGestureImageSettleCapped, "swipe の冒頭で消していない")
        s.setBody(#"{"ok":true,"imageSettleCapped":true}"#)
        try await c.swipe(.up)
        s.setBody(#"{"ok":true}"#)
        try await c.drag(fromX: 0, fromY: 0, toX: 10, toY: 10, pressSeconds: 0, durationSeconds: 0.1)
        XCTAssertNil(c.lastGestureImageSettleCapped, "drag の冒頭で消していない")
    }

    /// 要求が失敗した(応答が読めない)ときも前の値を残さない = 冒頭で消している。残ると、失敗を握って続けた呼び手が
    /// 前の swipe の申告で木の整定を省く
    func testFailedGestureDoesNotKeepThePreviousReport() async throws {
        let (c, s) = try client(body: #"{"ok":true,"imageSettleCapped":true}"#)
        defer { s.stop() }
        try await c.swipe(.up)
        s.setBody("not json")
        _ = try? await c.swipe(.up)
        XCTAssertNil(c.lastGestureImageSettleCapped, "swipe の冒頭で消していない")
        s.setBody(#"{"ok":true,"imageSettleCapped":true}"#)
        try await c.drag(fromX: 0, fromY: 0, toX: 10, toY: 10, pressSeconds: 0, durationSeconds: 0.1)
        s.setBody("not json")
        _ = try? await c.drag(fromX: 0, fromY: 0, toX: 10, toY: 10, pressSeconds: 0, durationSeconds: 0.1)
        XCTAssertNil(c.lastGestureImageSettleCapped, "drag の冒頭で消していない")
    }

    func testDragCopiesTheBridgeReport() async throws {
        let (c, s) = try client(body: #"{"ok":true,"imageSettleCapped":true}"#)
        defer { s.stop() }
        try await c.drag(fromX: 0, fromY: 0, toX: 10, toY: 10, pressSeconds: 0, durationSeconds: 0.1)
        XCTAssertEqual(c.lastGestureImageSettleCapped, true)
    }

    /// in-app ドライバは中の BridgeClient の値を素通しする(in-app ブリッジは欄を載せないので常に nil)
    func testInAppDriverPassesThroughTheClient() async throws {
        let stub = try RecordingStubServer(body: #"{"ok":true}"#)
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()), udid: "booted", port: stub.port)
        try await driver.swipe(.up, intent: .gesture, path: nil)
        XCTAssertNil(driver.lastGestureImageSettleCapped)
    }

    /// 包むドライバは全部、直前の swipe / drag を受けたドライバの申告を素通しする(落とすと最外のドライバから
    /// 見えず、ホストは整定を省けない)。reachedEdgeOnLastSwipe を素通ししているドライバを全数とみなす
    func testEveryForwardingDriverForwardsTheReport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/FTBridgeClient"), includingPropertiesForKeys: nil)
        files.append(root.appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift"))
        var checked = 0
        for url in files where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            guard code.contains("public var reachedEdgeOnLastSwipe") else { continue }
            checked += 1
            XCTAssertTrue(code.contains("var lastGestureImageSettleCapped: Bool?"),
                          "\(url.lastPathComponent) が lastGestureImageSettleCapped を持たない")
        }
        XCTAssertGreaterThanOrEqual(checked, 7, "走査が届いていない")
    }
}
