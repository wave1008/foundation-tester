import XCTest

/// api live serve が cmd の読める型違い行を黙殺していた実地(L3): 型付き Decodable の
/// 全体失敗で無応答のまま「JSON でない行」と区別が付かず、拡張の SERVE_REQUEST_TIMEOUT で
/// serve ごと再起動していた。パース自体(decodeError の中身)は
/// Tests/FleetestTests/ApiLiveServeCommandParsingTests.swift が固定するので、ここは
/// handle が decodeError を最優先で終端イベントに変えて答えることを配線として縛る。
///
/// **2つ目の実地**: decodeError 分岐が actionResult だけを出して return していたため、
/// 拡張が次に来るはずの観測イベント(snapshot/frame)を20秒待ち続けて serve を再起動していた
/// (launch/pinch/tap の型違い行 = `{"cmd":"launch","bundle":""}` 等で発生)。ここは
/// 「frame は frame イベントだけ、それ以外は actionResult に続けて観測イベントを出す」を
/// ブロック単位で検分する(コメント中に `{`/`}` が無い前提の素朴な波カッコ対応で本体を切り出す)。
final class ApiLiveDecodeErrorWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `{` の直後(openBraceEnd)から対応する `}` までの範囲を返す(ネストを数えて対応を取る)
    private func balancedBraceBody(in code: String, afterOpenBrace openBraceEnd: String.Index) -> Range<String.Index> {
        var depth = 1
        var idx = openBraceEnd
        while idx < code.endIndex {
            let ch = code[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return openBraceEnd..<idx }
            }
            idx = code.index(after: idx)
        }
        return openBraceEnd..<code.endIndex
    }

    private struct MarkerNotFound: Error {}

    private func decodeErrorOpenRange(in code: String) throws -> Range<String.Index> {
        guard let handleRange = code.range(of: "private func handle(") else {
            XCTFail("handle が見当たらない")
            throw MarkerNotFound()
        }
        guard let openRange = code.range(
            of: "if let decodeError = command.decodeError {",
            range: handleRange.upperBound..<code.endIndex
        ) else {
            XCTFail("handle が command.decodeError を見ていない"
                + " — 型違いの行が無応答のまま黙殺される(実地 L3)")
            throw MarkerNotFound()
        }
        return openRange
    }

    /// decodeError の確認は通常の frame/refresh 分岐より前に行うこと
    /// (後回しにすると型違いの frame/refresh 行が黙って観測イベントへ流れる)
    func testDecodeErrorCheckPrecedesTheNormalFrameHandling() throws {
        let code = try source()
        let openRange = try decodeErrorOpenRange(in: code)
        let blockEnd = balancedBraceBody(in: code, afterOpenBrace: openRange.upperBound).upperBound
        guard let emitFrameRange = code.range(
            of: "await emitFrame(driver: driver, starter: starter, port: port)",
            range: blockEnd..<code.endIndex) else {
            return XCTFail("通常の frame 経路(emitFrame の呼び出し)が decodeError ブロックの"
                + " 後ろに見当たらない — decodeError の確認が後回しにされていないか確認すること")
        }
        XCTAssertTrue(openRange.lowerBound < emitFrameRange.lowerBound)
    }

    /// frame の型違い行は frame イベント(ok:false)だけで答え、actionResult も観測イベントも
    /// 出さずに終える(拡張の frame リクエストは frame イベントでしか解決しない)
    func testDecodeErrorForFrameEmitsOnlyAFrameEvent() throws {
        let code = try source()
        let openRange = try decodeErrorOpenRange(in: code)
        let body = String(code[balancedBraceBody(in: code, afterOpenBrace: openRange.upperBound)])
        guard let frameCaseRange = body.range(of: "if command.cmd == \"frame\" {") else {
            return XCTFail("decodeError ブロックが frame の型違いを特別扱いしていない"
                + "(frame は actionResult を待たないので、通常の actionResult(ok:false) だけでは"
                + " 拡張の frame リクエストが解決しない)")
        }
        let frameCaseBody = balancedBraceBody(in: body, afterOpenBrace: frameCaseRange.upperBound)
        let frameCaseText = String(body[frameCaseBody])
        XCTAssertTrue(frameCaseText.contains("ApiLiveFrameEvent(ok: false"),
                      "frame の型違いは ApiLiveFrameEvent(ok:false) で答えること"
                      + "(通常の frame 経路と同形)")
        XCTAssertFalse(frameCaseText.contains("ApiLiveActionResultEvent"),
                       "frame の型違いに actionResult を混ぜない"
                       + "(拡張の frame リクエストは actionResult を待たない)")
        XCTAssertTrue(frameCaseText.contains("return"),
                      "frame の型違いはここで終えること(観測イベントを出さない)")
    }

    /// frame 以外の型違い行は actionResult(ok:false) に続けて観測イベントを出す(通常経路と同形)。
    /// **操作(perform)は実行しない** —— 引数が壊れているので撃てる状態ではない
    func testDecodeErrorForOtherCommandsEmitsActionResultThenObservationWithoutPerforming() throws {
        let code = try source()
        let openRange = try decodeErrorOpenRange(in: code)
        let bodyRange = balancedBraceBody(in: code, afterOpenBrace: openRange.upperBound)
        let body = String(code[bodyRange])
        guard let frameCaseRange = body.range(of: "if command.cmd == \"frame\" {") else {
            return XCTFail("decodeError ブロックに frame の特別扱いが見当たらない")
        }
        let frameCaseBody = balancedBraceBody(in: body, afterOpenBrace: frameCaseRange.upperBound)
        let tail = String(body[frameCaseBody.upperBound...])
        XCTAssertTrue(tail.contains("ApiLiveActionResultEvent(ok: false"),
                      "frame 以外の型違いは actionResult(ok:false) で答えること")
        XCTAssertTrue(tail.contains("await emitObservation("),
                      "actionResult に続けて観測イベントを出すこと —— 拡張は続く snapshot で"
                      + " リクエストを解決するため、これが無いと20秒の SERVE_REQUEST_TIMEOUT で"
                      + " serve ごと再起動される(実地: launch/pinch/tap の型違い行で発生)")
        XCTAssertFalse(tail.contains("perform(command:"),
                       "型違いの行では操作(perform)を実行しないこと(引数が壊れている)")
        XCTAssertTrue(tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("return"),
                      "decodeError ブロックはここで終えること(以降の通常経路へフォールスルーしない)")
    }

    /// ファイル冒頭のプロトコルコメントも更新済みであること(片方だけ変えない)
    func testProtocolCommentDocumentsTheTypeErrorResponse() throws {
        let code = try source()
        XCTAssertTrue(code.contains("cmd は読めたが他の引数の型が違う行は無視しない"),
                      "プロトコルコメント(ファイル冒頭)が型違い行の扱いを説明していない")
        XCTAssertTrue(code.contains("frame は"),
                      "プロトコルコメントが frame と他コマンドで応答の形が違うことを説明していない")
    }
}
