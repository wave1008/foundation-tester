// launch 前ガードの判定。**ここが緩むとランナーが死ぬ**(未インストールの launch は
// XCUITest ランナーごと落とす。docs/verification.md)。
// 2026-08-06 の受け手報告: 同名の起動中シミュレータが2台あると「一意に引けない」で
// 素通りしていた —— どれにも入っていないなら宛先がどれでも未インストールと断定できる。

import XCTest
@testable import FTBridgeClient

final class InstalledAppCheckVerdictTests: XCTestCase {

    func testSingleCandidateIsDecisive() {
        XCTAssertEqual(InstalledAppCheck.verdict(deviceName: "iPhone 17 Pro", installedFlags: [true]),
                       .installed)
        XCTAssertEqual(InstalledAppCheck.verdict(deviceName: "iPhone 17 Pro", installedFlags: [false]),
                       .notInstalled)
    }

    /// **同名が複数でも、どれにも入っていなければ断定する**(ここが今回の修正点)
    func testNoneOfTheDuplicatesHasItSoItIsNotInstalled() {
        XCTAssertEqual(
            InstalledAppCheck.verdict(deviceName: "iPhone 17 Pro", installedFlags: [false, false, false]),
            .notInstalled)
    }

    /// 一部にだけ入っているなら宛先を特定できない = 断定しない(launch は通す)
    func testMixedDuplicatesStayUnknown() {
        guard case .unknown(let reason) = InstalledAppCheck.verdict(
            deviceName: "iPhone 17 Pro", installedFlags: [true, false]) else {
            return XCTFail("混在は unknown であること")
        }
        XCTAssertTrue(reason.contains("iPhone 17 Pro"), reason)
    }

    /// 名前が1台も一致しないときは黙らず理由を返す(ガードが素通ししたことを stderr に出すため)
    func testNoCandidateExplainsItself() {
        guard case .unknown(let reason) = InstalledAppCheck.verdict(
            deviceName: "iPhone 99", installedFlags: []) else {
            return XCTFail("候補ゼロは unknown であること")
        }
        XCTAssertTrue(reason.contains("iPhone 99"), reason)
    }
}
