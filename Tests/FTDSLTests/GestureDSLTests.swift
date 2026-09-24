// DSL の `gesture` が FlowStep(action: "gesture") を経由して実際にドライバへ届くことの通しの確認。
// 比率→絶対座標の写しは Tests/FTCoreTests/TouchGestureTests.swift(TouchGesture.resolve 単体)が持つので、
// ここは「DSL が積んだ FTFinger の並びがそのまま StepExecutor へ渡ること」だけを見る。

import XCTest
@testable import FTDSL
import FTCore

final class GestureDSLTests: XCTestCase {

    /// #pad を撃つ・gesture() を撃つの両方を記録するドライバ
    private final class RecordingDriver: AppDriver {
        private(set) var gestureCalls: [GestureRequest] = []
        var gestureError: Error?

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "other", identifier: "pad", label: nil,
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 100, y: 200, width: 200, height: 100), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}

        func gesture(_ request: GestureRequest) async throws {
            gestureCalls.append(request)
            if let gestureError { throw gestureError }
        }
    }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-gesture-dsl-test-\(UUID().uuidString).json"),
                    emit: { _ in })
    }

    /// セレクタ指定は**要素の枠**を対象に比率を写す(pinch と同じ規約)
    func testGestureWithSelectorSendsCoordinatesResolvedAgainstTheElementFrame() throws {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    gesture("#pad") {
                        FTFinger(x: 0.25, y: 0.5).move(x: 0.75, y: 0.5, durationSeconds: 0.3)
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, core.finalRecord.scenes.flatMap(\.steps).last?.description ?? "")
        XCTAssertEqual(driver.gestureCalls.count, 1)
        let fingers = try XCTUnwrap(driver.gestureCalls.first).fingers
        XCTAssertEqual(fingers.count, 1)
        let points = fingers[0].points
        XCTAssertEqual(points.count, 2)
        // 対象の枠は (100, 200, 200x100): rx=0.25 → x=100+200*0.25=150 / rx=0.75 → x=100+200*0.75=250
        XCTAssertEqual(points[0].x, 150, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 250, accuracy: 0.001)
        XCTAssertEqual(points[0].t, 0, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 250, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 250, accuracy: 0.001)
        XCTAssertEqual(points[1].t, 0.3, accuracy: 0.001)
    }

    /// セレクタ無しは**画面全体**が対象(PinchRegion で絞らない。pinch との違い)
    func testGestureWithoutSelectorTargetsTheWholeScreen() throws {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    gesture {
                        FTFinger(x: 0, y: 0).hold(seconds: 0.2)
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, core.finalRecord.scenes.flatMap(\.steps).last?.description ?? "")
        let points = try XCTUnwrap(driver.gestureCalls.first).fingers[0].points
        // 画面は (0, 0, 400x800) なので (0,0) はそのまま (0,0)
        XCTAssertEqual(points[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 0, accuracy: 0.001)
        XCTAssertEqual(points[1].t, 0.2, accuracy: 0.001)
    }

    /// 指を1本も積まない = 不正な指定。**デバイスに触らず失敗する**(TouchGesture.resolve の門)
    func testEmptyGestureFailsWithoutCallingTheDriver() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { gesture { } }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(driver.gestureCalls.count, 0, "指0本の不正な指定でドライバを撃ってはいけない")
        let reasons = core.finalRecord.scenes.flatMap(\.steps).compactMap { step -> String? in
            if case .failed(let reason) = step.status { return reason }
            return nil
        }
        XCTAssertTrue(reasons.contains { $0.contains("at least one finger") }, "\(reasons)")
    }

    /// `maxGestureSeconds:` を上書きすれば既定 10 秒を超える総所要も通ること
    /// (FlowStep.maxGestureSeconds を経由してそのまま TouchGesture.resolve のキャップへ渡る)
    func testMaxGestureSecondsOverrideReachesTheGestureCap() {
        let driver = RecordingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    gesture(maxGestureSeconds: 30) {
                        FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 15)
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, core.finalRecord.scenes.flatMap(\.steps).last?.description ?? "")
        XCTAssertEqual(driver.gestureCalls.count, 1)
    }
}
