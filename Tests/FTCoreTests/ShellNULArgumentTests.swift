import Foundation
import XCTest
@testable import FTCore

/// 引数に NUL を含むコマンドは起動せず Swift のエラーで断る(2026-10-15 の負荷テスト: `Process` が ObjC 例外で
/// abort し、`ft_open_url` の url "\u0000" で fleetest-mcp ごと落ちた)
extension ShellTimeoutTests {
    func testArgumentWithNULThrowsInsteadOfAborting() {
        XCTAssertThrowsError(try Shell.run(["/bin/echo", "a\u{0}b"])) { error in
            guard case ShellError.argumentContainsNUL(let index) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(index, 1)
        }
        XCTAssertEqual(try Shell.run(["/bin/echo", "ab"]).status, 0)
    }

    /// `Shell` を通らずに `Process` を直に起こす経路も、起こす前に NUL を断る(compose の command・gateway の exec 要求から届く。
    /// 起こすと親の run ごと abort する = Codex レビュー 2026-10-15)
    func testDirectProcessLaunchesCheckNULFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for (file, from) in [("Sources/fleetest/ServicesSession.swift", "func runLong("),
                             ("Sources/FTCore/ServiceGateway.swift", "private func execute(")] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            guard let start = text.range(of: from),
                  let check = text.range(of: "ProcessArguments.firstNULIndex(", range: start.upperBound..<text.endIndex),
                  let run = text.range(of: "try process.run()", range: start.upperBound..<text.endIndex) else {
                return XCTFail("\(file): \(from) no longer checks NUL before process.run()")
            }
            XCTAssertLessThan(check.lowerBound, run.lowerBound, file)
        }
    }
}
