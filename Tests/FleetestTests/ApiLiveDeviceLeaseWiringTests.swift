import XCTest

/// api live serve が台の印(LiveDeviceLease)を書く配線(実地 B5): ライブ操作が印を1つも
/// 書いていなかったため、`api stop-device` 等の門(run-lease / MCP の印しか読まない)が
/// ライブ操作中の台を無言で止めていた。印そのものの読み書きは
/// Tests/FleetestTests/LiveDeviceLeaseTests.swift が固定するので、ここは配線
/// (作る・毎コマンド更新する・終了時に消す)をソース走査で縛る。
final class ApiLiveDeviceLeaseWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// run() は起動直後に印を作り、最初のコマンドを待たずに1度書くこと
    func testRunCreatesTheLeaseAndRefreshesItImmediately() throws {
        let code = try source()
        guard let makeRange = code.range(of: "LiveDeviceLease.make(") else {
            return XCTFail("LiveDeviceLease.make の呼び出しが見当たらない")
        }
        guard let refreshRange = code.range(
            of: "deviceLease?.refresh()", range: makeRange.upperBound..<code.endIndex) else {
            return XCTFail("作った直後に deviceLease?.refresh() を呼んでいない"
                + " — 最初のコマンドまで印が無い隙ができる")
        }
        XCTAssertTrue(makeRange.upperBound < refreshRange.lowerBound)
    }

    /// handle() はコマンドが通るたびに(型違い・未知の cmd を含め)印を更新すること
    func testHandleRefreshesTheLeaseOnEveryCommand() throws {
        let code = try source()
        guard let handleRange = code.range(of: "private func handle(") else {
            return XCTFail("handle が見当たらない")
        }
        guard let paramsEnd = code.range(of: ") async {", range: handleRange.upperBound..<code.endIndex)
        else {
            return XCTFail("handle のシグネチャが見当たらない — テストを見直すこと")
        }
        XCTAssertTrue(code[handleRange.upperBound..<paramsEnd.lowerBound].contains("deviceLease: LiveDeviceLease?"),
                      "handle は deviceLease を受け取ること")
        let bodyStart = paramsEnd.upperBound
        let firstStatement = String(code[bodyStart...].prefix(400))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decodeErrorRange = firstStatement.range(of: "if let decodeError") else {
            return XCTFail("handle の本体が見当たらない — テストを見直すこと")
        }
        let beforeFirstBranch = firstStatement[firstStatement.startIndex..<decodeErrorRange.lowerBound]
        XCTAssertTrue(beforeFirstBranch.contains("deviceLease?.refresh()"),
                      "handle は最初の分岐(decodeError)より前に deviceLease?.refresh() を呼ぶこと"
                      + " — 型違い・未知の cmd で終わる回も台を駆動している事実に変わりは無い")
    }

    /// handle の呼び出し元(run のループ)が deviceLease を渡していること
    func testRunPassesTheLeaseIntoHandle() throws {
        let code = try source()
        guard let callRange = code.range(of: "await handle(command: command,") else {
            return XCTFail("handle の呼び出しが見当たらない")
        }
        let call = String(code[callRange.lowerBound...].prefix(300))
        XCTAssertTrue(call.contains("deviceLease: deviceLease"),
                      "run() は handle へ deviceLease を渡すこと")
    }

    /// serve の終了(stdin EOF / シグナル)で自分の印を消すこと。消さないと、使っていない台を
    /// 他プロセスが「対話セッションが使用中」として避け続ける
    func testServeReleasesTheLeaseAfterTheCommandLoopEnds() throws {
        let code = try source()
        guard let loopRange = code.range(of: "for await line in lines {") else {
            return XCTFail("コマンドループが見当たらない")
        }
        guard let loopEnd = code.range(of: "\n        }", range: loopRange.upperBound..<code.endIndex)
        else {
            return XCTFail("コマンドループの終端が見当たらない — テストを見直すこと")
        }
        let afterLoop = String(code[loopEnd.upperBound...].prefix(300))
        XCTAssertTrue(afterLoop.contains("deviceLease?.release()"),
                      "コマンドループを抜けたら deviceLease?.release() で自分の印を消すこと")
    }
}
