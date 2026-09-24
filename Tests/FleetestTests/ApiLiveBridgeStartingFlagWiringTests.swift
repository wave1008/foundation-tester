import XCTest

/// live serve の全イベント(actionResult/snapshot/frame)が持つ必須フィールド `bridgeStarting`
/// (LiveBridgeAutoStarter が自動起動を進行中か)の配線を固定する。実際の値は actor の状態
/// (.starting)から来るため、デバイス無しでは実行時の値そのものは確かめられない——ここは
/// 「3構造体とも必須の Bool として持ち encode すること」「失敗イベントは annotated(...) の
/// 後で starter の状態を読むこと」「suffix() がもう進捗の文言を運ばないこと」をソース走査で縛る。
final class ApiLiveBridgeStartingFlagWiringTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 3イベント構造体すべてが bridgeStarting を必須(非 Optional)フィールドとして持ち、
    /// encode(to:) でも書き出すこと(版と契約の同期: 後方互換の Optional 化・decodeIfPresent
    /// 相当の読み替えは置かない方針。ここは拡張側での decode ではなく Swift 側の encode だが、
    /// 「新しい欄は必須にする」規律は同じ)
    func testAllThreeEventStructsDeclareAndEncodeBridgeStarting() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        for structName in ["ApiLiveActionResultEvent", "ApiLiveSnapshotEvent", "ApiLiveFrameEvent"] {
            guard let structRange = code.range(of: "struct \(structName): Encodable {") else {
                XCTFail("\(structName) が見当たらない")
                continue
            }
            guard let closeRange = code.range(of: "\n}\n", range: structRange.upperBound..<code.endIndex) else {
                XCTFail("\(structName) の閉じ括弧が見当たらない")
                continue
            }
            let body = String(code[structRange.upperBound..<closeRange.lowerBound])
            XCTAssertTrue(body.contains("let bridgeStarting: Bool"),
                          "\(structName) は bridgeStarting を必須の Bool で持つこと"
                          + "(Optional にすると版と契約の同期の方針[後方互換シムを置かない]に反する)")
            XCTAssertTrue(body.contains("CodingKeys.self")
                          && body.contains(".encode(bridgeStarting, forKey: .bridgeStarting)"),
                          "\(structName).encode(to:) が bridgeStarting を書き出していない")
        }
    }

    /// 失敗イベントは annotated(...) の**後**に starter の状態を読むこと(先に読むと、
    /// annotated が noteConnectionRefused() で idle→starting へ遷移させた直後の自動起動を
    /// 「していない」と誤って報告する)
    func testFailureEmitsReadBridgeStartingAfterAnnotated() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        var searchStart = code.startIndex
        var checked = 0
        while let annotatedCallRange = code.range(
            of: "await annotated(error, starter: starter", range: searchStart..<code.endIndex) {
            let tail = String(code[annotatedCallRange.upperBound...].prefix(400))
            XCTAssertTrue(tail.contains("bridgeStartingFlag(starter)"),
                          "annotated の呼び出し直後(400文字以内)に bridgeStartingFlag(starter) が"
                          + "見当たらない — 呼び出し順が入れ替わっていないか確認すること"
                          + "(先に読むと遷移前の idle を拾う)")
            checked += 1
            searchStart = annotatedCallRange.upperBound
        }
        XCTAssertEqual(checked, 3, "annotated の呼び出し箇所(actionResult/snapshot/frame それぞれの"
                       + " catch 節)が3箇所であること。増減していたらこのテストの前提を見直すこと")
    }

    /// starting の進捗はもう suffix() の文言(旧 "(Auto-starting the XCUITest bridge. …)")では
    /// 運ばない —— bridgeStarting フィールドに一本化したので、文言側に同じ情報を二重に残さない
    /// (残すと、拡張が起動中の失敗を中立表示に倒してもエラー文言側にだけ古い案内が残る)
    func testStartingSuffixNoLongerCarriesTheAutoStartingText() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        XCTAssertFalse(code.contains("Auto-starting the XCUITest bridge"),
                       "starting の suffix() が旧文言をまだ返している — bridgeStarting フィールドと"
                       + "二重に進捗を伝えないこと")
        guard let suffixRange = code.range(of: "private func suffix() -> String {") else {
            return XCTFail("suffix() が見当たらない")
        }
        guard let startingCaseRange = code.range(
            of: "case .starting:", range: suffixRange.upperBound..<code.endIndex) else {
            return XCTFail(".starting のケースが見当たらない")
        }
        guard let failedCaseRange = code.range(
            of: "case .failed(", range: startingCaseRange.upperBound..<code.endIndex) else {
            return XCTFail(".failed のケースが見当たらない")
        }
        let startingBody = String(code[startingCaseRange.upperBound..<failedCaseRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(startingBody, "return \"\"",
                       ".starting は空文字を返すこと(進捗は isStarting/bridgeStarting フィールドで伝える)")
    }

    /// isStarting(bridgeStarting の唯一の元)が actor に存在すること
    func testIsStartingComputedPropertyExists() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        XCTAssertTrue(code.contains("var isStarting: Bool"),
                      "LiveBridgeAutoStarter.isStarting が見当たらない"
                      + "(ApiLiveCommand.swift の bridgeStartingFlag の唯一の元)")
    }
}
