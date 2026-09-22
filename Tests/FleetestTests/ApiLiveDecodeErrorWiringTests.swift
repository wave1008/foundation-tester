import XCTest

/// api live serve が cmd の読める型違い行を黙殺していた実地(L3): 型付き Decodable の
/// 全体失敗で無応答のまま「JSON でない行」と区別が付かず、拡張の SERVE_REQUEST_TIMEOUT で
/// serve ごと再起動していた。パース自体(decodeError の中身)は
/// Tests/FleetestTests/ApiLiveServeCommandParsingTests.swift が固定するので、ここは
/// handle が decodeError を最優先で actionResult に変えて答えることを配線として縛る。
final class ApiLiveDecodeErrorWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testHandleAnswersDecodeErrorBeforeAnyOtherBranch() throws {
        let code = try source()
        guard let handleRange = code.range(of: "private func handle(") else {
            return XCTFail("handle が見当たらない")
        }
        guard let decodeErrorRange = code.range(
            of: "if let decodeError = command.decodeError", range: handleRange.upperBound..<code.endIndex
        ) else {
            return XCTFail("handle が command.decodeError を見ていない"
                + " — 型違いの行が無応答のまま黙殺される(実地 L3)")
        }
        guard let frameRange = code.range(
            of: "if command.cmd == \"frame\"", range: handleRange.upperBound..<code.endIndex) else {
            return XCTFail("frame 分岐が見当たらない")
        }
        XCTAssertTrue(decodeErrorRange.upperBound < frameRange.lowerBound,
                      "decodeError の確認は frame/refresh の分岐より前に行うこと"
                      + "(後回しにすると型違いの frame/refresh 行が黙って観測イベントへ流れる)")
        let decodeErrorBranch = String(code[decodeErrorRange.lowerBound..<frameRange.lowerBound])
        XCTAssertTrue(decodeErrorBranch.contains("ApiLiveActionResultEvent(ok: false"),
                      "decodeError は actionResult(ok:false) で答えること")
        XCTAssertTrue(decodeErrorBranch.contains("return"),
                      "decodeError で答えたら以降の処理(driver 操作・観測)へ進まないこと")
    }

    /// ファイル冒頭のプロトコルコメントも更新済みであること(片方だけ変えない)
    func testProtocolCommentDocumentsTheTypeErrorResponse() throws {
        let code = try source()
        XCTAssertTrue(code.contains("cmd は読めたが他の引数の型が違う行は無視しない"),
                      "プロトコルコメント(ファイル冒頭)が型違い行の扱いを説明していない")
    }
}
