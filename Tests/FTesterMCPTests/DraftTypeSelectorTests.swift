// 記録した手を**どの木で名付けるか**(`MCPServer.namingSnapshot`。2026-08-13)。
//
// witness: Google メッセージの「新しい会話」で `ft_type ref:<#ContactSearchField>` を撃つと、
// **`#id` を持つ欄なのに**下書きが `// TODO: no stable selector — type` になった(3/3 再現)。
// 一時計測で機構を確かめた —— 記録時点の `lastSnapshots` は**入力後の世代**で、ref が引けない:
//
//     REC action=tap  ref=14 refs=1,2,3,…    → 引ける
//     REC action=type ref=21 refs=26,27,28,… → 引けない
//
// **偽ドライバではこの流れを作れない**(中間の読み直しが起きず lastSnapshots が進まない)ので、
// 判定を純粋関数へ切り出してここで固定する。流れ側の確認は実機で行った(修正後 2/2)。

import XCTest
import FTCore
@testable import ftester_mcp

final class DraftTypeSelectorTests: XCTestCase {

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
}
