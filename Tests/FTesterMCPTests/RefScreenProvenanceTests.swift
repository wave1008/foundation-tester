// ref を採った木と、撃つ直前の木が違うことの警告(2026-08-15・Simulator で再現)。
//
// 既存の警告はどれも「要素の見え方」を見るので、同じ id・同じラベル・**同じ frame** の
// 別インスタンスを掴んだときに1つも当たらない。実測(E2EAppCMP)—— セレクタ画面で
// #btn_back(ref 350)を採り、ツールの外から simctl openurl でライフサイクル画面へ進めてから
// 撃つと `tap [350] done.` だけを返し、ライフサイクル画面の #btn_back を叩いた。
// isStale も当たらない(間に snapshot を挟んでいないので ref は最新世代のまま)。
//
// 判定は**しきい値を持たない**。類似度で「別画面」を当てる案は固定コーパスの実測で棄却済み
// (同じ画面の別状態 0.33 と別画面 0.30/0.35 が重なり、別画面で 0.92 のペアもある)。

import XCTest
import FTCore
@testable import ftester_mcp

final class RefScreenProvenanceTests: XCTestCase {

    private func element(_ ref: Int, id: String, label: String,
                         y: Double = 78, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 76, height: 48), depth: 3)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.ftester.e2e",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    /// witness の最小形: シェル(#btn_back)は同じで中身が入れ替わった2画面
    private var selector: SnapshotResponse {
        tree([element(350, id: "btn_back", label: "戻る"),
              element(352, id: "txt_screen_title", label: "セレクタ", y: 90, type: "staticText"),
              element(354, id: "btn_allow", label: "許可", y: 190)])
    }
    private var lifecycle: SnapshotResponse {
        tree([element(299, id: "btn_back", label: "戻る"),
              element(301, id: "txt_screen_title", label: "ライフサイクル", y: 90, type: "staticText"),
              element(304, id: "btn_session_inc", label: "セッション+1", y: 222)])
    }

    private func note(_ takenFrom: SnapshotResponse?, _ fresh: SnapshotResponse,
                      isStale: Bool = false) -> String {
        MCPServer.screenChangedUnderRefNote(
            ref: 350, takenFrom: takenFrom, fresh: fresh, isStale: isStale,
            matched: element(350, id: "btn_back", label: "戻る"))
    }

    /// **本命**: 木が別物になっていたら言う
    func testFiresWhenTheTreeIsNoLongerTheOneTheRefCameFrom() {
        let message = note(selector, lifecycle)
        XCTAssertTrue(message.contains("[350]"), message)
        XCTAssertTrue(message.contains("ft_snapshot"), "撮り直しを勧めていない: \(message)")
        XCTAssertFalse(message.hasSuffix(" "), "末尾に余白を残さない: \(message)")
        XCTAssertTrue(message.hasPrefix(" note:"), "既存の警告群と同じ書式であること: \(message)")
    }

    /// 木が同じなら黙る(通常の再照合を邪魔しない)
    func testStaysSilentWhenTheTreeIsUnchanged() {
        XCTAssertEqual(note(selector, selector), "")
    }

    /// **isStale のときは黙る** —— 既存の「older snapshot」注記が同じことを言うので二重になる
    func testStaysSilentWhenTheStaleNoteAlreadySaysIt() {
        XCTAssertEqual(note(selector, lifecycle, isStale: true), "")
    }

    /// 出自が分からなければ断じない
    func testStaysSilentWhenTheOriginIsUnknown() {
        XCTAssertEqual(note(nil, lifecycle), "")
    }

    /// **frame だけ違う = 同じ画面をスクロールしただけ**。比較キーに frame を混ぜる退行を殺す
    /// (スクロールのたびに全タップへ偽の警告が付く)
    func testStaysSilentWhenOnlyTheFramesMoved() {
        let scrolled = tree(selector.elements.map {
            ElementInfo(ref: $0.ref, type: $0.type, identifier: $0.identifier, label: $0.label,
                        value: $0.value, placeholder: $0.placeholder, enabled: $0.enabled,
                        frame: FTRect(x: $0.frame.x, y: $0.frame.y - 120,
                                      width: $0.frame.width, height: $0.frame.height),
                        depth: $0.depth)
        })
        XCTAssertEqual(note(selector, scrolled), "",
                       "スクロールしただけの同じ画面で言ってはいけない")
    }

    /// **ref の採番だけ違っても黙る**(世代が変わると ref はずれる。比較キーに ref を混ぜる退行)
    func testStaysSilentWhenOnlyTheRefNumbersDiffer() {
        let renumbered = tree(selector.elements.map {
            ElementInfo(ref: $0.ref + 1000, type: $0.type, identifier: $0.identifier,
                        label: $0.label, value: $0.value, placeholder: $0.placeholder,
                        enabled: $0.enabled, frame: $0.frame, depth: $0.depth)
        })
        XCTAssertEqual(note(selector, renumbered), "")
    }

    /// ラベルが1つ変わっただけでも木は別物(同一性はラベルを含む)。
    /// **時計のような自動更新が誤検知源**になるので、実機で発火率を測ったうえで入れている
    func testFiresWhenASingleLabelChanged() {
        let ticked = tree([element(350, id: "btn_back", label: "戻る"),
                           element(352, id: "txt_screen_title", label: "セレクタ", y: 90,
                                   type: "staticText"),
                           element(354, id: "btn_allow", label: "許可しない", y: 190)])
        XCTAssertFalse(note(selector, ticked).isEmpty)
    }

    // MARK: - 配線(純粋関数が正しくても応答に載らなければ意味が無い)
    //
    // **この形は本プロジェクトで何度も踏んでいる**(AppDriver の既定ディスパッチ・
    // ラッパードライバ5つの転送漏れ)。純粋関数のテストだけだと、`verifiedRef` から
    // 呼び出しを外す変異が**1本も落ちない**ことを実際に確認したので足した。

    /// **本命の配線**: snapshot を撮った後、ツールの外で画面が変わった状態で ft_tap すると、
    /// 応答に警告が載る(witness と同じ筋書き。台本の1枚目が「撃つ直前の木」)
    func testTheWarningReachesTheTapResponse() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = selector
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        driver.scriptedSnapshots = [lifecycle, lifecycle]
        let result = try await server.call(tool: "ft_tap", args: ["ref": 350])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("no longer matches"),
                      "画面が変わったことが応答に載っていない: \(text)")
        XCTAssertTrue(text.contains("ft_snapshot"), text)
    }

    /// **陰性対照**: 画面が変わっていなければ、同じ経路で警告は載らない
    /// (これが無いと「常に出す」変異を殺せない)
    func testTheResponseStaysQuietWhenTheScreenIsUnchanged() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = selector
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        driver.scriptedSnapshots = [selector, selector]
        let result = try await server.call(tool: "ft_tap", args: ["ref": 350])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertFalse(text.contains("no longer matches"), text)
    }
}
