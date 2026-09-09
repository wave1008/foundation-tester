// `fleetest run --junit` の書き出し先は **run を始める前**に断る(判定は FTCore.JUnitOutputPath)。
// 判定そのものは JUnitOutputPathTests が持つ。ここが固定するのは**配線** —— validate() から
// 呼ばれていなければ、レポートは 20 分走った後に書けないと分かる(純粋関数側が緑でも起きる)。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunJUnitPathValidationTests: XCTestCase {

    func testUnwritableJUnitPathIsRejectedBeforeTheRunStarts() {
        XCTAssertThrowsError(try RunScenarios.parse(["--junit", "/etc/hosts/junit.xml"])) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("--junit"), "どのオプションの話か名指しすること: \(message)")
            XCTAssertTrue(message.contains("cannot be written"), "書けないと言うこと: \(message)")
        }
    }

    func testWritableJUnitPathIsAccepted() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-junit-validate-\(UUID().uuidString)/junit.xml").path
        XCTAssertNoThrow(try RunScenarios.parse(["--junit", path]))
    }

    /// --junit を渡していないときは何も検査しない(既定の run を止めない)
    func testNoJUnitOptionIsUntouched() {
        XCTAssertNoThrow(try RunScenarios.parse([]))
    }
}
