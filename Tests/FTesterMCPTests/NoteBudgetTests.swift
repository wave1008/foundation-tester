// 注記の**本数**のラチェット(2026-08-13)。
//
// 注記には足す力しか働かない。監査で応答を読めば「もっと分かりやすく言えたはず」は必ず何か
// 出るので、評価者が読む限り本数は単調に増える(docs/mcp-audit-rounds.md
// §「自作の機構を監査しているとき、それは収穫ではない」——  ブラウザ5ラウンドで実バグは
// 3→3→4→4→4 と減らないまま、その大半が**前のラウンドで入れた注記の手直し**だった)。
//
// 止める機構は本来 `Scripts/mcp-bench.sh` の**手数**だが、**実 web ページの形は今のタスク集合で
// 測れない**(Bench/README.md §「ここで測れないもの」。offline の盤面が無く、ライブの web を
// 叩くタスクは足さないと決めてある)。つまり**いちばん注記を産んでいる形に、止める機構が無い**。
//
// このテストはその穴を塞ぐ代用ではなく、**増やすことを意識的な操作にする**ためのもの。
// 本数を変えるには、この数を書き換える = 差分に必ず現れる = 台帳へ根拠を書く動機になる。

import XCTest
@testable import ftester_mcp

final class NoteBudgetTests: XCTestCase {

    /// 2026-08-13 時点の本数。
    ///
    /// **増やすときに要る根拠**(どちらか。台帳 docs/mcp-audit-rounds.md へ書く):
    /// - `Scripts/mcp-bench.sh` で**手数が動いた**(`--variant` で黙らせた版と比べて `tools` が増える)
    /// - 実機の witness + 固定コーパス全数で**誤検知0**(手数を測れない形の場合。
    ///   ただしコーパスに無い形については何も言っていないので、**次のラウンドで当てに行く**)
    ///
    /// **減らすときも書き換える**(等号で照合しているのは、消したことも差分に出すため)。
    static let budget = 17

    /// **等号**で照合する。`<=` にすると「上限に余裕があるうちは黙って増やせる」ことになり、
    /// ラチェットとして機能しない(`knownSilent` を等号で照合しているのと同じ理由 ——
    /// 免除表・予算表が現状追認の置き場になるのを防ぐ)
    func testNoteCountMatchesTheBudget() {
        let keys = NoteCatalog.snapshotNotes.map(\.key).sorted()
        XCTAssertEqual(
            keys.count, Self.budget,
            "注記の本数が予算と違う(実測 \(keys.count) / 予算 \(Self.budget))。"
            + "増やすなら NoteBudgetTests.budget の宣言にある根拠を用意して台帳へ書き、"
            + "この数を更新すること。減らしたときも更新する。現在の鍵: \(keys)")
    }

    /// **交互規則の支え**: 検分の回に「ついでに1本」足されたことを、この2本のどちらかが必ず捕まえる。
    /// 本数が同じまま**鍵が入れ替わった**場合(1本消して1本足す)は上のテストが素通りするので、
    /// 鍵の集合そのものも固定する
    func testNoteKeysMatchTheRecordedSet() {
        let expected: Set<String> = [
            "addressBarNote", "ambiguousLabelsNote", "bulkExemptNote", "duplicateIDsNote",
            "duplicateRegionNote", "emptyTreeNote", "ghostNote", "gridWithoutHeaderNote",
            "keyboardCoverageNote", "missingPageContentNote", "scrollFrameCandidates",
            "sliverNote", "truncatedLabelNote", "truncationNote", "unlabeledClickablesNote",
            "urlishLabelsNote", "webViewGapNote",
        ]
        let actual = Set(NoteCatalog.snapshotNotes.map(\.key))
        XCTAssertEqual(
            actual, expected,
            "注記の鍵の集合が変わった(足りない: \(expected.subtracting(actual).sorted()) /"
            + " 増えた: \(actual.subtracting(expected).sorted()))。"
            + "本数が同じでも入れ替えは意識的な操作にする —— 台帳へ書いてからここを更新すること")
    }
}
