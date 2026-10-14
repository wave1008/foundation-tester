import XCTest
@testable import fleetest

/// ランタイムの自動選択の規則。探り自体(CLI を撃つ)はここでは行わない。
final class ServicesRuntimeLocatorTests: XCTestCase {
    /// 自動で Apple の常駐サービスを起こすのは Docker が使えないときだけ。明示なら起こす。`allowStart` false は常に起こさない
    func testAutoModeStartsAppleOnlyWhenDockerIsUnusable() {
        XCTAssertFalse(ServicesRuntimeLocator.mayStartApple(explicit: false, dockerUsable: true, allowStart: true))
        XCTAssertTrue(ServicesRuntimeLocator.mayStartApple(explicit: false, dockerUsable: false, allowStart: true))
        XCTAssertTrue(ServicesRuntimeLocator.mayStartApple(explicit: true, dockerUsable: true, allowStart: true))
        XCTAssertFalse(ServicesRuntimeLocator.mayStartApple(explicit: true, dockerUsable: false, allowStart: false))
        XCTAssertFalse(ServicesRuntimeLocator.mayStartApple(explicit: false, dockerUsable: false, allowStart: false))
    }
}
