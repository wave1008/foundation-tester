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
@testable import fleetest_mcp

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
                      isStale: Bool = false, actedSinceTakenFrom: Bool = false,
                      takenRightAfterOwnAction: Bool = false,
                      loadingNoteShownBefore: Bool = false) -> String {
        MCPServer.screenChangedUnderRefNote(
            ref: 350, takenFrom: takenFrom, fresh: fresh, isStale: isStale,
            matched: element(350, id: "btn_back", label: "戻る"),
            actedSinceTakenFrom: actedSinceTakenFrom,
            takenRightAfterOwnAction: takenRightAfterOwnAction,
            loadingNoteShownBefore: loadingNoteShownBefore)
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

    /// このセッション自身が撃った直前の操作で木が変わったのに、
    /// 「他プロセス/人が動かした」と誤って名指ししない
    func testDoesNotBlameExternalActorsWhenThisSessionActedSinceTheRefWasTaken() {
        let message = note(selector, lifecycle, actedSinceTakenFrom: true)
        XCTAssertTrue(message.contains("this session's own actions"), message)
        XCTAssertFalse(message.contains("nothing this session did"), message)
        XCTAssertFalse(message.contains("another process or a person"), message)
    }

    /// **陰性**: 従来どおり、外部要因の可能性を言う(このセッションが何もしていない形)
    func testStillBlamesExternalActorsWhenThisSessionDidNotAct() {
        let message = note(selector, lifecycle, actedSinceTakenFrom: false)
        XCTAssertTrue(message.contains("nothing this session did"), message)
    }

    /// **その木が自分の操作の直後の読みなら、外部要因を名指ししない**(読み込みの途中だった可能性を言う)
    func testDoesNotBlameExternalActorsWhenTheRefCameFromTheReadRightAfterOwnAction() {
        let message = note(selector, lifecycle, takenRightAfterOwnAction: true)
        XCTAssertTrue(message.contains("was read while the screen was still updating after this session's own last"), message)
        XCTAssertFalse(message.contains("another process or a person"), message)
    }

    /// **「操作の直後の読み」の注記は1セッション1回**(地図の検索では ref を撃つたびに出ていた = 計測で指摘)。
    /// 外部要因の注記は回数で黙らせない(別の事実を言うので)
    func testTheReadRightAfterOwnActionNoteIsSaidOnlyOnce() {
        XCTAssertEqual(note(selector, lifecycle, takenRightAfterOwnAction: true, loadingNoteShownBefore: true), "")
        XCTAssertTrue(note(selector, lifecycle, loadingNoteShownBefore: true).contains("nothing this session did"))
    }

    // MARK: - 地図の地点(畳まれる飾りの葉)

    /// 地図の地点 `#VKPointFeature`(畳まれる群 = bulkGroupMinimum 件以上の飾りの葉)
    private func pins(_ labels: [String], firstRef: Int) -> [ElementInfo] {
        labels.enumerated().map { offset, label in
            ElementInfo(ref: firstRef + offset, type: "other", identifier: "VKPointFeature",
                        label: label, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(offset * 10), y: 300, width: 30, height: 30), depth: 3)
        }
    }

    /// **地点の出し入れだけでは言わない**。実測(Apple マップの経路画面): `#VKPointFeature` 133件の増減だけで
    /// 「このセッションは何もしていないのに画面が変わった」と毎回言っていた
    func testStaysSilentWhenOnlyTheMapPinsChanged() {
        let count = SnapshotRenderer.bulkGroupMinimum + 5
        let taken = tree(selector.elements + pins((0..<count).map { "地点\($0)" }, firstRef: 500))
        let fresh = tree(selector.elements + pins((0..<count).map { "別の地点\($0)" }, firstRef: 500))
        XCTAssertEqual(note(taken, fresh), "")
    }

    /// 地点を除いた残りが変わっていれば従来どおり言う
    func testStillFiresWhenTheRestOfTheTreeChangedOnAMapScreen() {
        let count = SnapshotRenderer.bulkGroupMinimum + 5
        let mapPins = pins((0..<count).map { "地点\($0)" }, firstRef: 500)
        XCTAssertFalse(note(tree(selector.elements + mapPins), tree(lifecycle.elements + mapPins)).isEmpty)
    }

    /// **撃つ相手が地点そのものなら、地点の変化も比べる**(別の地点を同じ番号で掴んだ形を黙らせない)
    func testStillComparesThePinsWhenTheRefIsAPin() {
        let count = SnapshotRenderer.bulkGroupMinimum + 5
        let taken = tree(selector.elements + pins((0..<count).map { "地点\($0)" }, firstRef: 500))
        let fresh = tree(selector.elements + pins((0..<count).map { "別の地点\($0)" }, firstRef: 500))
        let message = MCPServer.screenChangedUnderRefNote(
            ref: 500, takenFrom: taken, fresh: fresh, isStale: false,
            matched: fresh.elements.first { $0.ref == 500 }!, actedSinceTakenFrom: false,
            takenRightAfterOwnAction: false, loadingNoteShownBefore: false)
        XCTAssertFalse(message.isEmpty)
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

    /// このセッション自身が直前に ft_tap で撃ってから木が変わった状態で、
    /// 別の(古い世代の)ref を撃つと、応答は「このセッション自身の操作が原因かもしれない」と
    /// 言う ——「他プロセス/人が動かした」とは言わない(実測 5/5)
    func testTheResponseAttributesTheChangeToThisSessionsOwnPriorTap() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = selector
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        // このセッション自身の操作(#btn_allow, ref 354)。まだ木は変わっていないので
        // verifiedRef が撮り直す fresh は同一の木(selector)のまま
        _ = try await server.call(tool: "ft_tap", args: ["ref": 354])

        // その後、木が変わる(このセッションの外の何かのせいかもしれないし、今の tap の
        // 結果かもしれない —— ここでは「セッションは何か撃った」ことだけが分かっていればよい)
        driver.scriptedSnapshots = [lifecycle, lifecycle]
        let result = try await server.call(tool: "ft_tap", args: ["ref": 350])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("this session's own actions"), text)
        XCTAssertFalse(text.contains("nothing this session did"), text)
    }

    /// **配線**: 自分の ft_tap の snapshotAfter で読んだ木から ref を採り、その後で木が変わった(読み込みの続き)
    /// 状態で撃つと、外部要因ではなく「操作の直後の読みだった」と言う。実測(Apple マップ・Google マップ):
    /// ft_type の snapshotAfter の候補を押すと「アプリ・他プロセス・人が動かした」と言っていた
    func testTheResponseSaysTheRefCameFromTheReadRightAfterThisSessionsAction() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = selector
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        // 撃つ直前の木は selector のまま、撃った後の読みは lifecycle(このセッションの操作の結果)
        driver.scriptedSnapshots = [selector, lifecycle]
        let after = try await server.call(tool: "ft_tap", args: ["ref": 354, "snapshotAfter": true])
        let afterText = after.compactMap { $0["text"] as? String }.joined()
        let match = try XCTUnwrap(afterText.firstMatch(of: /\[(\d+)\] button "セッション\+1"/),
                                  afterText)
        let ref = try XCTUnwrap(Int(match.1))

        // 何もしていないのに読み込みの続きで木が変わる
        let settled = tree(lifecycle.elements + [element(305, id: "txt_result", label: "読み込み完了",
                                                         y: 300, type: "staticText")])
        driver.scriptedSnapshots = [settled, settled]
        let result = try await server.call(tool: "ft_tap", args: ["ref": ref])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("was read while the screen was still updating after this session's own last"), text)
        XCTAssertFalse(text.contains("another process or a person"), text)

        // 2回目の同じ形は黙る(配線: 言った回にだけ印が立つ)
        driver.scriptedSnapshots = [settled, lifecycle]
        let again = try await server.call(tool: "ft_tap", args: ["ref": ref, "snapshotAfter": true])
        let againText = again.compactMap { $0["text"] as? String }.joined()
        let match2 = try XCTUnwrap(againText.firstMatch(of: /\[(\d+)\] button "セッション\+1"/), againText)
        let ref2 = try XCTUnwrap(Int(match2.1))
        driver.scriptedSnapshots = [settled, settled]
        let secondResult = try await server.call(tool: "ft_tap", args: ["ref": ref2])
        let second = try XCTUnwrap(secondResult.first?["text"] as? String)
        XCTAssertFalse(second.contains("still updating"), second)
        XCTAssertFalse(second.contains("another process or a person"), second)
    }

    /// **陰性対照**: 素の ft_snapshot で読んだ木(操作を伴わない呼び出し)なら、従来どおり外部要因の可能性を言う
    func testAPlainSnapshotAfterAnActionIsNotMarkedAsTheReadRightAfterIt() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = selector
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [selector]
        _ = try await server.call(tool: "ft_tap", args: ["ref": 354])
        driver.scriptedSnapshots = []
        driver.snapshotResponse = lifecycle
        let plain = try await server.call(tool: "ft_snapshot", args: [:])
        let plainText = plain.compactMap { $0["text"] as? String }.joined()
        let match = try XCTUnwrap(plainText.firstMatch(of: /\[(\d+)\] button "セッション\+1"/),
                                  plainText)
        let ref = try XCTUnwrap(Int(match.1))

        let settled = tree(lifecycle.elements + [element(305, id: "txt_result", label: "読み込み完了",
                                                         y: 300, type: "staticText")])
        driver.scriptedSnapshots = [settled, settled]
        let result = try await server.call(tool: "ft_tap", args: ["ref": ref])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("nothing this session did"), text)
    }
}
