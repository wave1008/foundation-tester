// BridgeAPI.gestureDurationViolation: XCUITest ランナーが合成タッチを送る前に断る値域。
// MCP/ライブ操作の入口(ArgumentBounds)を通らない経路(DSL 等)からも桁外れの秒数が
// ランナーへ直接届きうるため、ランナー自身が同じ上限で断る。**ランナーは常に cap:
// gestureSecondsCeiling(絶対上限)で断る**(要求ごとの上書きは受け取らない。方針の判定は
// ホスト側 = StepExecutor / ArgumentBounds)。
// リテラルの 10 / 60 / 10.5 / 60.5 を書く(production の定数を期待値に流用しない)。

import XCTest
import FTCore

final class GestureDurationViolationTests: XCTestCase {

    // MARK: - gestureDurationViolation(cap: 10 = 既定)

    func testWithinBoundIsAccepted() {
        for seconds in [0.0, 0.05, 5.0, 9.999] {
            XCTAssertNil(BridgeAPI.gestureDurationViolation("press", seconds: seconds, cap: 10),
                        "\(seconds) は境界内のはず")
        }
    }

    func testBoundaryTenIsAccepted() {
        XCTAssertNil(BridgeAPI.gestureDurationViolation("press", seconds: 10, cap: 10))
    }

    func testJustOverTenIsRejected() {
        let message = BridgeAPI.gestureDurationViolation("press", seconds: 10.0001, cap: 10)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("press") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("10") == true, message ?? "nil")
    }

    /// cap が既定(10 = gestureSecondsCeiling 未満)のときだけ、上書きの案内を添える
    func testOverDefaultCapMentionsTheOverride() {
        let message = BridgeAPI.gestureDurationViolation("press", seconds: 10.5, cap: 10)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("maxGestureSeconds") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("60") == true, message ?? "nil")
    }

    /// 実地の再現値(1e9 = testmanagerd を肥大させた値)。Int へ畳まず trap しないこと
    func testFarOverTenIsRejectedWithoutTrapping() {
        let message = BridgeAPI.gestureDurationViolation("press", seconds: 1_000_000_000.0, cap: 10)
        XCTAssertTrue(message?.contains("1e+09") == true, message ?? "nil")
    }

    func testNonFiniteIsRejected() {
        XCTAssertNotNil(BridgeAPI.gestureDurationViolation("drag", seconds: .nan, cap: 10))
        XCTAssertNotNil(BridgeAPI.gestureDurationViolation("drag", seconds: .infinity, cap: 10))
    }

    func testNegativeIsRejected() {
        let message = BridgeAPI.gestureDurationViolation("swipe", seconds: -1, cap: 10)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("swipe") == true, message ?? "nil")
    }

    func testZeroIsAccepted() {
        XCTAssertNil(BridgeAPI.gestureDurationViolation("pinch", seconds: 0, cap: 10))
    }

    /// `what` はそのまま文言に載る(呼び手が press/drag/swipe/pinch を名乗るための引数)
    func testMessageNamesTheCaller() {
        for what in ["press", "drag", "swipe", "pinch"] {
            let message = BridgeAPI.gestureDurationViolation(what, seconds: 999, cap: 10)
            XCTAssertTrue(message?.hasPrefix(what) == true, message ?? "nil")
        }
    }

    // MARK: - gestureDurationViolation(cap: 60 = 絶対上限。ランナーが実際に使う cap)

    func testBoundarySixtyIsAcceptedWithCeilingCap() {
        XCTAssertNil(BridgeAPI.gestureDurationViolation("press", seconds: 60, cap: 60))
    }

    /// cap がちょうど絶対上限のときは、これ以上上げようが無いので上書きの案内を付けない
    func testOverCeilingCapDoesNotMentionTheOverride() {
        let message = BridgeAPI.gestureDurationViolation("press", seconds: 60.5, cap: 60)
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("maxGestureSeconds") == true, message ?? "nil")
    }

    // MARK: - maxGestureSecondsViolation(上書き値そのものの検査)

    func testOverrideWithinBoundIsAccepted() {
        for value in [0.001, 10.0, 30.0, 60.0] {
            XCTAssertNil(BridgeAPI.maxGestureSecondsViolation(value), "\(value) は境界内のはず")
        }
    }

    func testOverrideZeroIsRejected() {
        XCTAssertNotNil(BridgeAPI.maxGestureSecondsViolation(0))
    }

    func testOverrideNegativeIsRejected() {
        XCTAssertNotNil(BridgeAPI.maxGestureSecondsViolation(-1))
    }

    func testOverrideNonFiniteIsRejected() {
        XCTAssertNotNil(BridgeAPI.maxGestureSecondsViolation(.nan))
        XCTAssertNotNil(BridgeAPI.maxGestureSecondsViolation(.infinity))
    }

    func testOverrideJustOverSixtyIsRejected() {
        let message = BridgeAPI.maxGestureSecondsViolation(60.5)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("maxGestureSeconds") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("60") == true, message ?? "nil")
    }

    // MARK: - 文言の主語(引数名に " duration" を重ねない)

    func testArgumentNameIsTheSubjectAtTheHostGate() {
        let message = ArgumentBounds.gestureCapViolation(["holdSeconds": 15.0])
        XCTAssertEqual(message, "holdSeconds must be 10 seconds or less (got 15);"
            + " pass maxGestureSeconds: (up to 60) to allow longer")
    }

    func testDSLNamesTheArgumentAndTheCommand() {
        XCTAssertEqual(FlowStep.gestureDurationViolation(action: "tap", duration: 15, maxGestureSeconds: nil),
                       "holdSeconds of tap must be 10 seconds or less (got 15);"
                        + " pass maxGestureSeconds: (up to 60) to allow longer")
        XCTAssertEqual(FlowStep.gestureDurationViolation(action: "pinchOut", duration: 30, maxGestureSeconds: 20),
                       "durationSeconds of pinchOut must be 20 seconds or less (got 30);"
                        + " pass maxGestureSeconds: (up to 60) to allow longer")
    }

    /// ランナー(操作名を渡す)は従来どおり「press duration」
    func testRunnerWordingKeepsTheGestureName() {
        XCTAssertEqual(BridgeAPI.gestureDurationViolation("press", seconds: 60.5, cap: 60),
                       "press duration must be 60 seconds or less (got 60.5)")
    }

    // MARK: - 定数の同期(ArgumentBounds が二重定義していないこと)

    func testArgumentBoundsSharesTheSameCeilingValue() {
        XCTAssertEqual(ArgumentBounds.numeric["maxGestureSeconds"]?.max, 60)
    }
}
