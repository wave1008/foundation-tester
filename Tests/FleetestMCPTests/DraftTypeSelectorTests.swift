// 記録した手を**どの木で名付けるか**(`MCPServer.namingSnapshot`。2026-08-13)。
//
// witness: Google メッセージの「新しい会話」で `ft_type ref:<#ContactSearchField>` を撃つと、
// **`#id` を持つ欄なのに**下書きが `// TODO: no stable selector — type` になった(3/3 再現)。
// 一時計測で機構を確かめた —— 記録時点の `lastSnapshots` は**入力後の世代**で、ref が引けない:
//
//     REC action=tap  ref=14 refs=1,2,3,…    → 引ける
//     REC action=type ref=21 refs=26,27,28,… → 引けない
//
// **偽ドライバで流れを作るには、操作後の木の「顔ぶれ」を変える必要がある**(2026-08-13 に判明):
// `adoptSnapshot` は identity(ref/type/identifier/**label**)が同じなら世代を使い回すので、
// **value だけが変わる木では ref が進まず、この欠陥は再現しない**。実機では入力後に候補一覧が
// 現れて顔ぶれが変わるため世代が進む。下の配線テストはその形を台本で作っている。

import XCTest
import FTCore
@testable import fleetest_mcp

final class DraftTypeSelectorTests: XCTestCase {

    private static func field(_ value: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "TextField", identifier: "ContactSearchField", label: nil,
                    value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 60, y: 77, width: 285, height: 42), depth: 1, focused: true)
    }

    /// 実機の形: 入力すると**候補一覧が現れて木の顔ぶれが変わる**(= 世代が進む)
    private static func screen(_ value: String?, suggestion: Bool) -> SnapshotResponse {
        var elements = [field(value)]
        if suggestion {
            elements.append(ElementInfo(ref: 2, type: "Clickable", identifier: nil,
                                        label: "送信先 (555) 123-4567", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 7, y: 121, width: 346, height: 61),
                                        depth: 1))
        }
        return SnapshotResponse(sessionBundleID: "com.example",
                                screen: FTRect(x: 0, y: 0, width: 360, height: 808),
                                elements: elements, truncatedCount: 0)
    }

    private static func tree(_ refs: [Int]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example",
                         screen: FTRect(x: 0, y: 0, width: 360, height: 808),
                         elements: refs.map {
                             ElementInfo(ref: $0, type: "TextField",
                                         identifier: "ContactSearchField", label: nil,
                                         value: nil, placeholder: nil, enabled: true,
                                         frame: FTRect(x: 60, y: 77, width: 285, height: 42),
                                         depth: 1)
                         },
                         truncatedCount: 0)
    }

    /// **witness の形**: 最新の木は既に別世代で ref を持たない。世代の木で名付けること
    func testNamesFromTheGenerationTheRefCameFromWhenTheLatestTreeMovedOn() {
        let chosen = MCPServer.namingSnapshot(ref: 21, generation: Self.tree([20, 21, 22]),
                                              latest: Self.tree([26, 27, 28]))
        XCTAssertEqual(chosen?.elements.map(\.ref), [20, 21, 22],
                       "入力後の世代で名付けている(= #id を持つ欄でも下書きが TODO になる)")
    }

    /// 世代を持たない経路(座標タップ等)は従来どおり最新の木へ落ちる
    func testFallsBackToTheLatestTreeWhenThereIsNoGeneration() {
        let latest = Self.tree([1, 2])
        XCTAssertEqual(MCPServer.namingSnapshot(ref: 1, generation: nil, latest: latest)?
            .elements.map(\.ref), [1, 2])
    }

    /// **世代があっても、その ref を持っていなければ最新の木を使う**(古い世代を掴まない)
    func testIgnoresAGenerationThatDoesNotHoldTheRef() {
        let latest = Self.tree([9])
        XCTAssertEqual(MCPServer.namingSnapshot(ref: 9, generation: Self.tree([1, 2]),
                                                latest: latest)?.elements.map(\.ref), [9])
    }

    /// どちらにも無ければ nil(呼び出し側が「セレクタ無し」として記録する)
    func testReturnsTheLatestEvenWhenNeitherHoldsTheRef() {
        XCTAssertNil(MCPServer.namingSnapshot(ref: 5, generation: nil, latest: nil))
    }

    // MARK: - 配線(記録がこの判定を通ること)

    /// **判定だけを固定すると「呼び出しを外す」変異が生き残る**(実測)。ここは流れごと通す ——
    /// 台本は実機と同じ形にする(入力後に候補一覧が現れて**木の顔ぶれが変わる** = 世代が進む)。
    /// 顔ぶれが同じ木だと `adoptSnapshot` が世代を使い回し、**欠陥そのものが起きない**
    func testDraftKeepsTheTypeSelectorEvenWhenTheTreeMovedOnBeforeRecording() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen("名前を入力", suggestion: false)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example"])
        let shown = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(shown.first?["text"] as? String)
        let ref = try XCTUnwrap(Int(text.split(separator: "[")[1].split(separator: "]")[0]))
        // verifiedRef の撮り直し → 入力後(候補が出て顔ぶれが変わる)→ snapshotAfter
        driver.scriptedSnapshots = [
            Self.screen("名前を入力", suggestion: false),
            Self.screen("5551234567", suggestion: true),
            Self.screen("5551234567", suggestion: true),
            Self.screen("5551234567", suggestion: true),
        ]
        _ = try await server.call(tool: "ft_type",
                                  args: ["ref": ref, "text": "5551234567", "snapshotAfter": true])
        let content = try await server.call(tool: "ft_draft_scenario", args: [:])
        let draft = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(draft.contains("type(\"#ContactSearchField\""),
                      "下書きが入力の手のセレクタを失っている(記録が別世代の木で名付けた):\n\(draft)")
    }
}
