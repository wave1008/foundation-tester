// `fleetest remote exec` の到達確認(`echo $HOME` の ssh)が stdin を読まないことのソース走査。
//
// 読むと、続く本番の ssh(`api live serve` など stdin で命令を受ける子)へ渡すはずの stdin の先頭を
// ここで食べて捨てる。実地 2026-09-24: 他の機械の実機のライブ操作で、最初の frame が返らなかった
// (`(echo frame; sleep 20) | fleetest remote exec M1Ultra -- api live serve …` が何も出さずに終わる)。

import XCTest

final class RemoteExecStdinTests: XCTestCase {
    func testHomeProbeDoesNotReadStdin() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/RemoteSetupCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let exec = code.range(of: "commandName: \"exec\"") else {
            return XCTFail("remote exec の定義が見当たらない — テストを見直すこと")
        }
        let body = code[exec.upperBound...]
        guard let probe = body.range(of: "\"echo $HOME\"") else {
            return XCTFail("remote exec の到達確認が見当たらない — テストを見直すこと")
        }
        let lineStart = body[..<probe.lowerBound].lastIndex(of: "\n").map { body.index(after: $0) }
            ?? body.startIndex
        let line = body[lineStart..<probe.upperBound]
        XCTAssertTrue(line.contains("\"-n\""),
                      "remote exec の到達確認の ssh は -n で stdin を読まないこと(本番の子の stdin を食べる): \(line)")
    }
}
