// 起動前の検査で「入っていない」と確定した失敗が、結果 JSON で `app-not-installed` になること。
// **checkFailed は名乗らない** —— 入っているか分からない状態を「入っていない」と書くと、
// 読み手が「端末の準備の問題」と断定してしまう(2026-08-20)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class LaunchPreflightKindTests: XCTestCase {

    func testNotInstalledDeclaresItsKind() {
        let error = LaunchPreflightError.appNotInstalled(bundleID: "com.example", udid: "UDID")
        XCTAssertEqual(StepExecutor.failureKind(thrown: error), .appNotInstalled)
    }

    /// 検査そのものが失敗したときは**言えない**(nil)
    func testCheckFailureIsNotClassified() {
        let error = LaunchPreflightError.checkFailed(bundleID: "com.example", detail: "xcrun missing")
        XCTAssertNil(StepExecutor.failureKind(thrown: error))
    }
}
