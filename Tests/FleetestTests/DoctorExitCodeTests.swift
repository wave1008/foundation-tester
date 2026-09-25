// `fleetest doctor`(全体レポート)の exit code。**❌ を出したら非0**で終わる
// (`--fm-only` / `--roots-only` と同じ向き)。全体だけ常に 0 を返していたため、
// exit code で門を作る呼び手(スキル・CI)が赤い行を見落としていた。
//
// レポート本体は実 I/O(FM の実呼び出し・xcodebuild・adb)なので、ここは
// **数え漏れと抜けを走査で固定する**: ❌ を出す分岐と `problems += 1` の本数が揃っていること、
// 最後に集計して `throw ExitCode(1)` していること。

import XCTest

final class DoctorExitCodeTests: XCTestCase {

    private func doctorBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/DoctorCommand.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "struct Doctor: AsyncParsableCommand")
        else { throw XCTSkip("struct Doctor が見つからない") }
        // Doctor は DoctorCommand.swift 内で最後の struct(後続の "\nstruct " は無い)なので
        // 見つからなければファイル末尾までを本体とする
        let end = text.range(of: "\nstruct ", range: start.upperBound..<text.endIndex)?.lowerBound
            ?? text.endIndex
        return String(text[start.upperBound..<end])
    }

    /// レポート経路の ❌ はすべて集計に載る(FM text / FM vision / tool root / xcodebuild /
    /// xcodegen / Bridge APK の6つ)
    func testEveryFailureLineIsCounted() throws {
        let body = try doctorBody()
        XCTAssertEqual(body.components(separatedBy: "problems += 1").count - 1, 6,
                       "❌ を出す分岐は6つ(FM text / FM vision / tool root / xcodebuild / xcodegen / Bridge APK)")
        XCTAssertTrue(body.contains("if !fm.available { problems += 1 }"), "FM text を数える")
        XCTAssertTrue(body.contains("if !vision.available, !visionUnsupported { problems += 1 }"),
                      "FM vision を数える(OS 非対応は数えない)")
        XCTAssertTrue(body.contains("if !printRoots() { problems += 1 }"), "tool root の失敗を数える")
    }

    /// 数えた結果で必ず非0になる
    func testReportExitsNonZeroWhenSomethingFailed() throws {
        let body = try doctorBody()
        XCTAssertTrue(body.contains("if problems > 0 {"), "集計してから抜ける")
        XCTAssertTrue(body.contains("throw ExitCode(1)"), "非0で抜ける")
    }
}
