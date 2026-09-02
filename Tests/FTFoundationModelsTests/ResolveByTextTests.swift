import XCTest
import FTCore
@testable import FTFoundationModels

/// `FMReplayDelegate.resolveByText` は heal/triage の応答文字列(`elementText` / triage の
/// summary 中の指し示し)から要素を引く。モデルはこのリポジトリのセレクタ記法(`#id`)や
/// @Guide の「the quoted string」指示につられて、SnapshotRenderer が実際には描かない表記
/// (`#btn_x` / 引用符で囲んだラベル)を返すことがある(2026-09-02 実測: `#btn_heal_v2` を
/// 剥がせず nil を返し、正しい修復候補を黙って捨てていた)。表記のゆれを剥がすだけで、
/// あいまい一致は増やさないことを固定する。
final class ResolveByTextTests: XCTestCase {

    private func element(ref: Int, id: String?, label: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                          elements: elements, truncatedCount: 0)
    }

    /// 実測ケース: triage が id を `#` 付きで返す
    func testStripsLeadingHashFromId() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("#btn_heal_v2", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    /// 既存の挙動の回帰: `id=` 接頭辞
    func testStripsIdEqualsPrefix() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("id=btn_heal_v2", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    /// 既存の挙動の回帰: 接頭辞無しの生の id
    func testResolvesBareId() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("btn_heal_v2", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    /// 既存の挙動の回帰: ラベルでの解決
    func testResolvesByLabel() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("修復対象", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    /// @Guide の「the quoted string」指示につられてラベルを引用符ごと返す形
    func testStripsSurroundingDoubleQuotesFromLabel() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("\"修復対象\"", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    func testStripsSurroundingSingleQuotesFromLabel() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let resolved = FMReplayDelegate.resolveByText("'修復対象'", in: snap)
        XCTAssertEqual(resolved?.ref, 1)
    }

    /// `#` を剥がした結果が空になる形は nil(存在しない要素を誤って拾わない)
    func testHashOnlyResolvesToNil() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        XCTAssertNil(FMReplayDelegate.resolveByText("#", in: snap))
    }

    func testEmptyStringResolvesToNil() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        XCTAssertNil(FMReplayDelegate.resolveByText("", in: snap))
    }

    /// 一致順序: 完全一致 identifier が包含一致より優先される
    /// (`btn_a` と `btn_a_extra` を両方置いた木で "btn_a" を引く → `btn_a` 自身が返る)
    func testExactIdentifierMatchWinsOverContains() {
        let snap = snapshot([
            element(ref: 1, id: "btn_a_extra", label: nil),
            element(ref: 2, id: "btn_a", label: nil),
        ])
        let resolved = FMReplayDelegate.resolveByText("btn_a", in: snap)
        XCTAssertEqual(resolved?.ref, 2)
    }

    /// 空文字ガードの境界: `identifier` が空文字("" であって nil ではない)の要素が木にあると、
    /// ガードの有無で結果が変わる —— ガードを外すと `$0.identifier == ""` が真になり、
    /// 無関係なその要素へ誤って解決してしまう(guard !raw.isEmpty をただの `if false` に
    /// 差し替える変異が、identifier が nil/非空のみの木では検出できなかった対策)
    func testHashOnlyWithEmptyIdentifierElementStillResolvesToNil() {
        let snap = snapshot([
            element(ref: 1, id: "", label: nil),
            element(ref: 2, id: "btn_heal_v2", label: "修復対象"),
        ])
        XCTAssertNil(FMReplayDelegate.resolveByText("#", in: snap))
    }

    func testEmptyStringWithEmptyIdentifierElementStillResolvesToNil() {
        let snap = snapshot([
            element(ref: 1, id: "", label: nil),
            element(ref: 2, id: "btn_heal_v2", label: "修復対象"),
        ])
        XCTAssertNil(FMReplayDelegate.resolveByText("", in: snap))
    }
}
