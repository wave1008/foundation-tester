import XCTest
@testable import FTCore

final class AnimationPolicyTests: XCTestCase {

    func testDefaultIsDisabledWhenUnset() {
        XCTAssertFalse(AnimationPolicy.animationsEnabled(environment: [:]))
    }

    func testAcceptedTruthyValues() {
        for value in ["1", "true", "TRUE", "on", "yes"] {
            XCTAssertTrue(
                AnimationPolicy.animationsEnabled(environment: [AnimationPolicy.environmentKey: value]),
                "\(value) は ON と読むべき")
        }
    }

    /// 未知の値は「無効化する」既定へ倒す(誤って有効になるより安全側)
    func testUnknownValuesFallBackToDisabled() {
        for value in ["0", "false", "off", "", "2", "ON!"] {
            XCTAssertFalse(
                AnimationPolicy.animationsEnabled(environment: [AnimationPolicy.environmentKey: value]),
                "\(value) は OFF と読むべき")
        }
    }

    func testAndroidScaleValue() {
        XCTAssertEqual(AnimationPolicy.androidScaleValue(animationsEnabled: true), "1")
        XCTAssertEqual(AnimationPolicy.androidScaleValue(animationsEnabled: false), "0")
    }

    /// アニメーションを残す = Reduce Motion を切る(反転を落とす)
    func testReduceMotionIsInverse() {
        XCTAssertFalse(AnimationPolicy.iosReduceMotion(animationsEnabled: true))
        XCTAssertTrue(AnimationPolicy.iosReduceMotion(animationsEnabled: false))
    }

    /// Developer options の3種すべてを対象にする(1つ落とすと残った1つでアニメが出る)
    func testCoversAllThreeScaleKeys() {
        XCTAssertEqual(Set(AnimationPolicy.androidScaleKeys), [
            "window_animation_scale", "transition_animation_scale", "animator_duration_scale",
        ])
    }
}
