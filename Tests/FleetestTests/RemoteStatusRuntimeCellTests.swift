// `fleetest remote status` の RUNTIME 列の検証。
//
// **警告だけの欄**(新しい検知はまず警告から)なので、守るのは誤って鳴らさない側 ——
// どちらかが読めない(Xcode の無い機械・旧形の出力)ときは「違う」ではなく不明にする。

import XCTest
@testable import fleetest

final class RemoteStatusRuntimeCellTests: XCTestCase {

    /// 実害の形(2026-09-10 M1Max): 手元は正式版・向こうはベータだけ → ⚠️
    func testBetaOnlyRunnerIsFlagged() {
        XCTAssertEqual(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434",
                                                           remote: "iOS 27.0: 24A5423a (beta)"), false)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434",
                                                        remote: "iOS 27.0: 24A5423a (beta)"),
                       "⚠️ iOS 27.0: 24A5423a (beta)")
    }

    func testMatchingRunnerIsGreen() {
        XCTAssertEqual(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434", remote: "iOS 27.0: 24A434"), true)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434", remote: "iOS 27.0: 24A434"),
                       "✅ iOS 27.0: 24A434")
    }

    /// 不明は「違う」に倒さない(倒すと Xcode の無い機械で毎回鳴る)
    func testUnknownOnEitherSideIsNotAMismatch() {
        XCTAssertNil(RemoteCommand.Status.runtimeMatches(local: nil, remote: "iOS 27.0: 24A434"))
        XCTAssertNil(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434", remote: nil))
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: nil, remote: "iOS 27.0: 24A434"), "iOS 27.0: 24A434")
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434", remote: nil), "-")
    }
}
