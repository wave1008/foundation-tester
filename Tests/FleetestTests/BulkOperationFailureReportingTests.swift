// 一括起動/停止/再起動の**集約の申告**(exit code と finished{ok})をソース走査で固定する。
//
// 規律は1つ: **全滅(1台以上あって0台成功)のときだけ ok:false + exit 1**。部分失敗は exit 0 の
// まま要約だけ出す(「1台の失敗で全体を落とさない」)。この分岐は緑の run では1度も通らず、
// コマンドの run() は台帳と実デバイスが要るので単体テストから到達できない —— 実際、
// 分岐を丸ごと消す変異が DeviceBooterShutdownAllTests / BootOutcomeSummarizerTests を
// 素通りした(2026-09-09)。**本数で数える** —— 「存在するか」だけだと5箇所のうち1つが
// 消えても緑のまま通る。

import XCTest

final class BulkOperationFailureReportingTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `summary.allFailed` の各分岐の中身(次の閉じ括弧まで)を返す
    private func allFailedBlocks(in source: String) -> [String] {
        source.components(separatedBy: "summary.allFailed").dropFirst().map { rest in
            String(rest.prefix(400))
        }
    }

    /// devices up / devices down --profile の2箇所。どちらも全滅で exit 1
    func testDevicesCommandExitsOneOnlyWhenEveryDeviceFailed() throws {
        let devices = try source("Sources/fleetest/DevicesCommand.swift")
        let blocks = allFailedBlocks(in: devices)
        XCTAssertEqual(blocks.count, 2,
                       "devices up と devices down --profile の2箇所が全滅を判定すること")
        for block in blocks {
            XCTAssertTrue(block.contains("throw ExitCode(1)"),
                          "全滅の分岐は exit 1 で落とすこと: \(block.prefix(120))")
        }
        // 部分失敗は exit 0 のまま要約だけ出す(up/down で1本ずつ)
        XCTAssertEqual(devices.components(separatedBy: "summary.succeededCount").count - 1, 2,
                       "up/down とも部分失敗の要約を出すこと(exit 1 に倒さない側の証拠)")
    }

    /// api start-all-devices / restart-devices / stop-all-devices の3箇所。
    /// NDJSON 経路は exit code に加えて finished{ok:false} も出す(拡張のバナーの根拠)
    func testApiDeviceCommandsReportOkFalseOnlyWhenEveryDeviceFailed() throws {
        let api = try source("Sources/fleetest/ApiDeviceCommands.swift")
        let blocks = allFailedBlocks(in: api)
        XCTAssertEqual(blocks.count, 3,
                       "start-all-devices / restart-devices / stop-all-devices の3箇所が全滅を判定すること")
        for block in blocks {
            XCTAssertTrue(block.contains("ok: false"),
                          "全滅の分岐は finished{ok:false} を出すこと: \(block.prefix(120))")
            XCTAssertTrue(block.contains("throw ExitCode(1)"),
                          "全滅の分岐は exit 1 で落とすこと: \(block.prefix(120))")
        }
        // 全滅で throw した ExitCode を外側の catch が握って finished を二重に出さないこと
        XCTAssertEqual(api.components(separatedBy: "catch let exitCode as ExitCode").count - 1, 3,
                       "3経路とも ExitCode を素通しする catch を持つこと")
    }
}
