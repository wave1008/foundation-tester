import XCTest
@testable import FTCore

/// 画像整定の上限の表(ユーザー決定の値)。値はリテラルで固定する(production の定数で期待値を書かない)
final class ImageSettleCapTests: XCTestCase {
    func testIOSTable() {
        XCTAssertEqual(ImageSettleCap.seconds(framework: .swiftUI, isAndroid: false), 3.7)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .uikit, isAndroid: false), 3.7)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .reactNative, isAndroid: false), 3.0)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .flutter, isAndroid: false), 3.0)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .compose, isAndroid: false), 4.4)
    }

    func testAndroidTable() {
        XCTAssertEqual(ImageSettleCap.seconds(framework: .androidView, isAndroid: true), 1.7)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .compose, isAndroid: true), 1.3)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .reactNative, isAndroid: true), 2.3)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .flutter, isAndroid: true), 1.4)
    }

    /// 分からないときはその OS の最大(短い側へ倒すと慣性の途中で返る)
    func testUnknownFallsBackToTheOSMaximum() {
        XCTAssertEqual(ImageSettleCap.seconds(framework: nil, isAndroid: false), 4.4)
        XCTAssertEqual(ImageSettleCap.seconds(framework: nil, isAndroid: true), 2.3)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .androidView, isAndroid: false), 4.4)
        XCTAssertEqual(ImageSettleCap.seconds(framework: .swiftUI, isAndroid: true), 2.3)
        // ブリッジ側の既定と一致すること(ランナーは FTCore の表を持たないので BridgeAPI に複製している)
        XCTAssertEqual(BridgeAPI.imageSettleCapSeconds, ImageSettleCap.iosFallbackSeconds)
    }

    /// スクロール容器の枠は各辺 10% 削って比べる(100×200 → 内側 80×160)。Android は値を複製している
    func testRegionInsetKeepsTheInnerEightyPercent() throws {
        XCTAssertEqual(BridgeAPI.imageSettleRegionInsetRatio, 0.1)
        let inner = BridgeAPI.imageSettleCompareRect(FTRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(inner, FTRect(x: 10, y: 20, width: 80, height: 160))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let android = try String(contentsOf: root.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"),
                                 encoding: .utf8)
        XCTAssertTrue(android.contains("IMAGE_SETTLE_REGION_INSET = 0.1;"), "Android の割合が BridgeAPI と違う")
        XCTAssertTrue(android.contains("IMAGE_SETTLE_QUIET_MS = 320;"), "Android の静止の窓(ユーザー決定 320ms)が変わった")
        let runner = try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift"),
                                encoding: .utf8)
        XCTAssertTrue(runner.contains("BridgeAPI.imageSettleCompareRect(rawRegion)"), "ランナーが内側で比べていない")
    }

    /// Android の撮影時刻: 実機は連続・エミュレータは ①50ms 後 ②変化中 50→100ms ③窓の中間と満了の2点(ユーザー決定。
    /// 根拠は nextCaptureAt の doc)。Java に単体テストの仕組みが無いので値と分岐を走査で固定する
    func testAndroidCaptureScheduleByDeviceType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let android = try String(contentsOf: root.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"),
                                 encoding: .utf8)
        XCTAssertTrue(android.contains("IMAGE_SETTLE_FIRST_GAP_MS = 50;"))
        XCTAssertTrue(android.contains("IMAGE_SETTLE_MAX_INTERVAL_MS = 100;"))
        XCTAssertTrue(android.contains("\"ranchu\".equals(Build.HARDWARE)"), "エミュレータの判定が変わった")
        XCTAssertTrue(android.contains("if (!emulator) return lastAt;"), "実機は待たずに撮る")
        XCTAssertTrue(android.contains("if (frames == 1) return firstAt + IMAGE_SETTLE_FIRST_GAP_MS;"))
        XCTAssertTrue(android.contains("changeStreak <= 1 ? IMAGE_SETTLE_FIRST_GAP_MS : IMAGE_SETTLE_MAX_INTERVAL_MS"))
        XCTAssertTrue(android.contains("long mid = lastChangeAt + quietMs / 2;"), "静止中は窓の中間で1枚")
        XCTAssertTrue(android.contains("return Math.max(lastAt, lastChangeAt + quietMs);"), "最後は窓の満了時刻ちょうど")
        XCTAssertTrue(android.contains("nextCaptureAt(IS_EMULATOR, frames, firstAt, lastAt, lastChangeAt,"),
                      "撮影ループが撮影時刻の関数を通っていない")
        XCTAssertFalse(android.contains("IMAGE_SETTLE_INTERVAL_MS"), "固定間隔は撤去済み")
    }

    /// ステップの実行が文脈を TaskLocal に載せ、BridgeClient がヘッダで渡す配線(型の効かない継ぎ目なので走査で固定)
    func testExecutorAndClientWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let executor = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor.swift"), encoding: .utf8)
        XCTAssertTrue(executor.contains("ImageSettlePlan.$context.withValue(.init(framework: uiFramework, isAndroid: isAndroid))"))
        let client = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"), encoding: .utf8)
        XCTAssertTrue(client.contains("ImageSettlePlan.context"))
        XCTAssertTrue(client.contains("headers[BridgeAPI.settleCapHeader]"))
        let android = try String(contentsOf: root.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java"),
                                 encoding: .utf8)
        XCTAssertTrue(android.contains("\"X-FT-Settle-Cap-Ms\""), "Android がヘッダ名を複製していない")
        XCTAssertTrue(android.contains("v >= 900 && v <= 10000"), "Android の受け取り範囲が BridgeAPI.imageSettleCapRangeMs と違う")
    }
}
