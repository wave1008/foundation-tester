// 待ちが外れたとき、前面に新しく出たもの(alert・ボタンだけの全面シート)を名指しする(MCPServer.appearedPromptNote)。
// 操作の応答では曖昧ラベル・重複 id の表の明細を畳み、ft_snapshot だけ満額にする(MCPServer.briefKeys)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPWaitMissPromptNoteTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ label: String?, id: String? = nil, depth: Int = 1,
                    y: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 20, y: y, width: 300, height: 44), depth: depth)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    func testANewSheetWithOnlyNewButtonsIsNamedAndAnOrdinaryScreenIsNot() {
        let before = tree([el(1, "button", "経路"), el(2, "button", "共有"), el(3, "button", "閉じる"),
                           el(4, "staticText", "立川駅")])
        // 実測の全面シート: 押せるのは「通知を有効にする / 今はしない」だけ
        let sheet = tree([el(10, "staticText", "友達が到着予定時刻を共有するときに通知を受信"),
                          el(11, "button", "通知を有効にする", y: 722), el(12, "button", "今はしない", y: 784)])
        let note = MCPServer.appearedPromptNote(before: before, now: sheet)
        XCTAssertTrue(note.contains("offers only \"通知を有効にする\" / \"今はしない\""), note)
        // **1つが前の画面にもあるボタンでも言う**(実測: 販促シートの「閉じる」は経路画面にもあり、黙った)
        let sheet2 = tree([el(10, "staticText", "友達が到着予定時刻を共有するときに通知を受信"),
                           el(11, "button", "通知を有効にする", y: 722), el(12, "button", "閉じる", y: 784)])
        XCTAssertTrue(MCPServer.appearedPromptNote(before: before, now: sheet2).contains("offers only"))
        // 押せる物が減っていない(= 同じ規模の別画面)なら言わない
        let bigger = tree([el(20, "button", "A"), el(21, "button", "B"), el(22, "button", "C"), el(23, "button", "D")])
        XCTAssertEqual(MCPServer.appearedPromptNote(before: bigger, now: tree([el(30, "button", "X"), el(31, "button", "Y"), el(32, "button", "Z"), el(33, "button", "W")])), "")
        // 押せる物が前回もあった(= 同じ画面の続き)なら言わない
        XCTAssertEqual(MCPServer.appearedPromptNote(before: before, now: tree([el(1, "button", "経路")])), "")
        // 比べる木が無ければ言わない
        XCTAssertEqual(MCPServer.appearedPromptNote(before: nil, now: sheet), "")
    }

    func testANewAlertIsNamedWithItsButtons() {
        let before = tree([el(1, "button", "経路")])
        let now = tree([el(1, "button", "経路"), el(2, "alert", "安全に目的地に到達するために"),
                        el(3, "button", "OK", depth: 2)])
        let note = MCPServer.appearedPromptNote(before: before, now: now)
        XCTAssertTrue(note.contains("安全に目的地に到達するために"), note)
        XCTAssertTrue(note.contains("buttons: \"OK\""), note)
        XCTAssertFalse(note.contains("alert alert"), "型名と語が重なった: \(note)")
    }

    /// **先頭・末尾の空白を持つラベルはそう言う**(Google マップの `"  埼京線"`)。無ければ言わない
    func testLabelsWithLeadingSpacesAreCalledOut() {
        let spaced = tree([el(1, "button", "  埼京線", y: 100), el(2, "button", "  埼京線", y: 300)])
        XCTAssertTrue(MCPServer.ambiguousLabelsNote(spaced).contains("really has them"))
        let plain = tree([el(1, "button", "埼京線", y: 100), el(2, "button", "埼京線", y: 300)])
        XCTAssertFalse(MCPServer.ambiguousLabelsNote(plain).contains("really has them"))
    }

    /// 畳んだ群の行の同じ理由は1回だけ末尾に言う(5群が同じ文を5回繰り返していた)。1群だけ・理由が違う行はそのまま
    func testASharedTrailingReasonIsSaidOnce() {
        let reason = "repeats inside #list; every alternative is index-based, so tap by ref instead."
        let lines = ["note: header", "  #a ×2: [1] [2] — \(reason)", "  #b ×3: [3] [4] [5] — \(reason)",
                     "  #c ×2: [6] [7] — none of these have a selector on this screen; tap by ref instead."]
        let folded = MCPServer.foldingSharedReasons(lines)
        XCTAssertEqual(folded, ["note: header", "  #a ×2: [1] [2]", "  #b ×3: [3] [4] [5]",
                                "  #c ×2: [6] [7] — none of these have a selector on this screen; tap by ref instead.",
                                "  (lines above with no trailing note: \(reason))"])
        XCTAssertEqual(MCPServer.foldingSharedReasons(Array(lines.prefix(2))), Array(lines.prefix(2)))
    }

    /// `once` の鍵はデバイスごと(1つのサーバを2つのエージェントが別のデバイスで共有すると、2人目が初出を見ていないのに
    /// 「初出の注記を見よ」と言われた)
    func testOnceIsCountedPerDevice() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.noteScope = "ios:8137"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F")
        server.noteScope = "android:emulator-5562"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F", "別のデバイスなのに短縮された")
        server.noteScope = "ios:8137"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "S")
    }

    /// **操作の応答では、操作できる要素を含まない群(レイアウト容器だけ)を表に並べない**。ft_snapshot は満額
    func testLayoutOnlyGroupsAreLeftOutOfActionResponses() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "保存", id: "save_btn", y: 100), el(2, "button", "保存", id: "save_btn", y: 600),
                                        el(3, "other", nil, id: "TextStackView", y: 200), el(4, "other", nil, id: "TextStackView", y: 700)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let full = try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(full.contains("#TextStackView ×2"), full)
        let action = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(action.contains("#save_btn ×2"), action)
        XCTAssertFalse(action.contains("#TextStackView ×2"), "容器だけの群を操作の応答に並べた: \(action)")
    }

    /// **操作の応答では表の明細を畳み、ft_snapshot では満額**(同じ木で比べる)
    func testSelectorTablesAreFoldedInActionResponsesButNotInFtSnapshot() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "保存", id: "save_top", y: 100),
                                        el(2, "button", "保存", id: "save_bottom", y: 600)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let full = try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(full.contains("[1] #save_top"), full)
        let action = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(action.contains("\"保存\" ×2"), "事実(×N)は残す: \(action)")
        XCTAssertFalse(action.contains("[1] #save_top"), "明細を畳んでいない: \(action)")
    }
}
