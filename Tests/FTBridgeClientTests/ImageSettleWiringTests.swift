import XCTest
@testable import FTBridgeClient
import FTCore

/// 画像整定(`X-FT-Settle-Mode: image`)の配線。ランナーは swift test でビルドされないので、ランナー側はソース走査で縛る
final class ImageSettleWiringTests: XCTestCase {
    private func runnerSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSettleModeHeaderValueIsImageOnly() {
        // 既定は画像整定。`tree` を明示したときだけヘッダを付けない
        XCTAssertEqual(BridgeClient.settleModeHeaderValue(mode: "image"), "image")
        XCTAssertEqual(BridgeClient.settleModeHeaderValue(mode: nil), "image")
        XCTAssertEqual(BridgeClient.settleModeHeaderValue(mode: ""), "image")
        XCTAssertNil(BridgeClient.settleModeHeaderValue(mode: "tree"))
    }

    private func headers(_ path: String, _ ctx: ImageSettlePlan.Context?, mode: String? = "image") -> [String: String] {
        BridgeClient.imageSettleHeaders(modeValue: mode, context: ctx, path: path)
    }

    func testPlanHeadersIOSSwiftUIScroll() {
        XCTAssertEqual(headers("/swipe", .init(framework: .swiftUI, isAndroid: false)), [
            "X-FT-Settle-Mode": "image", "X-FT-Settle-Cap-Ms": "3700", "X-FT-Settle-Quiet-Ms": "250",
            "X-FT-Settle-Event": "1"])
    }

    func testPlanHeadersIOSComposeTap() {
        XCTAssertEqual(headers("/tap", .init(framework: .compose, isAndroid: false)), [
            "X-FT-Settle-Mode": "image", "X-FT-Settle-Cap-Ms": "4400", "X-FT-Settle-Quiet-Ms": "250",
            "X-FT-Settle-Tree": "1"])
    }

    func testPlanHeadersIOSComposeScrollCarriesBackoff() {
        XCTAssertEqual(headers("/drag", .init(framework: .compose, isAndroid: false)), [
            "X-FT-Settle-Mode": "image", "X-FT-Settle-Cap-Ms": "4400", "X-FT-Settle-Quiet-Ms": "450",
            "X-FT-Settle-Backoff-Ms": "150"])
    }

    func testPlanHeadersAndroidViewScroll() {
        XCTAssertEqual(headers("/swipe", .init(framework: .androidView, isAndroid: true)), [
            "X-FT-Settle-Mode": "image", "X-FT-Settle-Cap-Ms": "1700", "X-FT-Settle-Quiet-Ms": "320"])
    }

    func testTreeModeAndMissingContextSendNoPlan() {
        XCTAssertEqual(headers("/swipe", .init(framework: .swiftUI, isAndroid: false), mode: nil), [:])
        XCTAssertEqual(headers("/swipe", nil), ["X-FT-Settle-Mode": "image"])
    }

    func testPlanWireLiterals() {
        XCTAssertEqual(BridgeAPI.settleQuietHeader, "X-FT-Settle-Quiet-Ms")
        XCTAssertEqual(BridgeAPI.settleEventHeader, "X-FT-Settle-Event")
        XCTAssertEqual(BridgeAPI.settleTreeHeader, "X-FT-Settle-Tree")
        XCTAssertEqual(BridgeAPI.settleBackoffHeader, "X-FT-Settle-Backoff-Ms")
        XCTAssertEqual(BridgeAPI.imageSettleQuietRangeMs, 50...2000)
        XCTAssertEqual(BridgeAPI.imageSettleBackoffRangeMs, 0...1000)
    }

    func testWireLiterals() {
        XCTAssertEqual(BridgeAPI.settleModeHeader, "X-FT-Settle-Mode")
        XCTAssertEqual(BridgeAPI.settleModeImage, "image")
        XCTAssertEqual(RunEnvironmentKeys.settleMode, "FT_SETTLE_MODE")
        XCTAssertEqual(BridgeAPI.imageSettleCapSeconds, 4.4)
        XCTAssertEqual(BridgeAPI.settleCapHeader, "X-FT-Settle-Cap-Ms")
        XCTAssertEqual(BridgeAPI.imageSettleCapRangeMs, 900...10_000)
        XCTAssertEqual(BridgeAPI.imageSettleQuietSeconds, 0.45)
        XCTAssertEqual(BridgeAPI.imageSettleCapNote(seconds: 3.7), "screen kept changing for 3.7s (image settle cap)")
    }

    func testClientSendsTheHeaderFromRequest() throws {
        let code = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"), encoding: .utf8)
        XCTAssertTrue(code.contains("for (name, value) in Self.imageSettleHeaders(modeValue: settleModeValue,"))
        XCTAssertTrue(code.contains("var headers = [BridgeAPI.settleModeHeader: modeValue]"))
        XCTAssertTrue(code.contains("RunEnvironmentKeys.settleMode"))
    }

    func testServerParsesTheHeader() throws {
        let code = try runnerSource("BridgeHTTPServer.swift")
        XCTAssertTrue(code.contains("BridgeAPI.settleModeHeader.lowercased()"))
        XCTAssertTrue(code.contains("settleMode: settleMode"))
    }

    /// 経路: 対象パスの表・swipe/drag の quiescence 省略・操作後の captureStill・上限定数・settlePending を立てない分岐
    func testRouterRunsCaptureStillOnTheMutatingAndGesturePaths() throws {
        let code = try runnerSource("BridgeRouter.swift")
        guard let set = code.range(of: "private static let imageSettlePaths: Set<String> = [") else {
            return XCTFail("imageSettlePaths が見当たらない — テストを見直すこと")
        }
        let line = String(code[set.upperBound...].prefix { $0 != "]" })
        for path in ["/swipe", "/drag", "/tap", "/type", "/clear", "/pressEnter", "/press"] {
            XCTAssertTrue(line.contains("\"\(path)\""), "\(path) が画像整定の対象から外れている")
        }
        for path in ["/session", "/home", "/appswitcher", "/rotate"] {
            XCTAssertFalse(line.contains("\"\(path)\""), "\(path) は検証の待ちが要る = 画像整定に入れない")
        }
        XCTAssertTrue(code.contains("if imageSettle, response.status == 200 {"), "操作の後に画像整定を回していない")
        XCTAssertTrue(code.contains("response = settledByImage(response, region: region, insetWholeScreen: isSwipe)"))
        XCTAssertTrue(code.contains("region = req.path?.region"), "/swipe の region を画像整定へ渡していない")
        XCTAssertTrue(code.contains("request.path == \"/swipe\""), "region の絞り込みは /swipe だけ")
        XCTAssertTrue(code.contains("if captureStill(region: region, insetWholeScreen: insetWholeScreen) { return response }"))
        guard let start = code.range(of: "private func captureStill(region: FTRect?, insetWholeScreen: Bool) -> Bool {") else {
            return XCTFail("captureStill が見当たらない")
        }
        let body = String(code[start.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("imageSettleQuietSeconds"), "時間窓を参照していない")
        XCTAssertTrue(code.contains("request.settleQuietMs.map { Double($0) / 1000 } ?? BridgeAPI.imageSettleQuietSeconds"),
                      "窓の既定が BridgeAPI の定数でない")
        XCTAssertTrue(body.contains("region"), "captureStill が region を使っていない")
        XCTAssertFalse(code.contains("imageSettleMatchingFrames"), "連続一致枚数の規則は撤去済み")
        XCTAssertTrue(code.contains("BridgeAPI.imageSettleCapSeconds"), "上限定数を参照していない")
        XCTAssertTrue(code.contains("BridgeAPI.imageSettleCapNote(seconds: imageSettleCapSeconds)"))
        XCTAssertTrue(code.contains("request.settleCapMs"), "ホストの上限ヘッダを読んでいない")
        XCTAssertEqual(code.components(separatedBy: "skip: skipSettle || (imageSettle && !imageSettleWaitEvent)").count - 1, 2,
                       "swipe(2経路)が画像整定の間 quiescence を飛ばしていない")
        XCTAssertTrue(code.contains("try skipSettle || (imageSettle && !imageSettleWaitEvent) ? QuiescenceWait.around(skip: true, body)"),
                      "drag が画像整定の間 quiescence を飛ばしていない")
        XCTAssertTrue(code.contains("combinedSnapshotNote(settleCapped: cap.settleCapped)"),
                      "持ち越した打ち切りの note を snapshot が出していない")
    }
}
