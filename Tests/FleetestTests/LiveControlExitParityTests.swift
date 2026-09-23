import XCTest

/// **利用者が次の一手を打つ経路は MCP(`ft_*`)とライブ操作(`api live serve`)の2つ**。どちらも
/// 「失敗したが、どうすればよいか」を返す役で、判定(FTCore / FTBridgeClient)は共有し文言だけ
/// 呼び手ごとに持つ、という規律がある。**片方にだけ配線すると、同じ状況で一方は出口を案内し
/// 他方は一次情報しか返さない** —— 実際にこの形で同じ型の不具合が3回続けて出た
/// (docs/maintainer-notes.md §45)。ここは**配線の有無だけ**を縛る(文言の中身は
/// ApiLiveConnectionHintTextTests・MCP 側の各テストが見る)。
///
/// **run(DSL)は対象外**: あちらは失敗をレポートへ残して自動回復する経路で、人が次の一手を
/// 打つ場ではない(レーンの離脱・再キューを自前で持つ)。
final class LiveControlExitParityTests: XCTestCase {

    /// 両方の経路が呼ぶ判定。**足すときは両方へ配線してから載せる** ——
    /// ライブ操作に要らないと判断したものはここへ載せない(載せないこと自体が判断の記録)
    private static let sharedJudgements = [
        // ブリッジが「固まった」のか「busy」なのか(対処が逆: 建て直し vs 待つ)
        "probeStatus",
        // Android のアクティブウィンドウの a11y 根が一時的に読めない(自然回復する)
        "isNoReadableWindow",
        // 画面が凍結して古いフレームを返し続けている(絵を信じてはいけない)
        "StaleFrameDetector",
    ]

    /// **コメントを落としてから走査する** —— 判定の名前は doc コメントにも書かれているので、
    /// 素のまま検索すると配線を消してもコメントだけで通ってしまう(変異で実際に素通りした)
    private static func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// MCP は複数ファイルに分かれているので連結して見る
    private func mcpSources() throws -> String {
        let dir = Self.repoRoot().appendingPathComponent("Sources/fleetest-mcp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "Sources/fleetest-mcp が読めていない — テストを見直すこと")
        return try names.map { try Self.code(of: dir.appendingPathComponent($0)) }
            .joined(separator: "\n")
    }

    private func liveControlSource() throws -> String {
        try Self.code(of: Self.repoRoot()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift"))
    }

    /// 走査が届いていることの確認(空文字を検索すると何を書いても通る)
    func testBothSourcesAreActuallyRead() throws {
        XCTAssertTrue(try mcpSources().contains("MCPServer"), "MCP のソースを読めていない")
        XCTAssertTrue(try liveControlSource().contains("api live serve")
            || (try liveControlSource().contains("ApiLiveCommand")),
                      "ライブ操作のソースを読めていない")
    }

    func testMCPWiresEverySharedJudgement() throws {
        let code = try mcpSources()
        for judgement in Self.sharedJudgements {
            XCTAssertTrue(code.contains(judgement),
                          "MCP が \(judgement) を呼んでいない —— 共有しない判断なら"
                          + " sharedJudgements から外し、理由をコメントに残すこと")
        }
    }

    /// **これが落ちたら、ライブ操作だけが出口を失っている**(3回の不具合の型そのもの)
    func testLiveControlWiresEverySharedJudgement() throws {
        let code = try liveControlSource()
        for judgement in Self.sharedJudgements {
            XCTAssertTrue(code.contains(judgement),
                          "ライブ操作が \(judgement) を呼んでいない —— MCP にだけ配線すると、"
                          + "同じ状況で人が UI で詰まったときに一次情報しか出ない")
        }
    }
}
