// BackEffect の純ロジック(back の前後で木が同一かの判定)を検証する。デバイスに触れない。

import XCTest
@testable import FTCore

final class BackEffectTests: XCTestCase {
    private func element(label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private let screenA = [ElementInfo]()  // 空の木でも指紋は取れる(要素数0も1つの指紋)
    private var treeA: [ElementInfo] { [element(label: "A")] }
    private var treeB: [ElementInfo] { [element(label: "B")] }

    private func snap(_ elements: [ElementInfo], keyboard: FTRect? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                         elements: elements, truncatedCount: 0, keyboardFrame: keyboard)
    }

    // MARK: - shouldWarn: 同一 → 注記あり

    func testShouldWarnWhenAllObservationsAreIdenticalToBefore() {
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA)]))
        // ポーリングで複数回撮っても、全部同一なら警告(MCP のポーリング経路を模した形)
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA), snap(treeA), snap(treeA)]))
    }

    // MARK: - shouldWarn: 相違 → 注記なし

    func testShouldWarnIsFalseWhenAnyObservationDiffersFromBefore() {
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeB)]))
        // 最初は同一でも、途中で変わっていれば back は効いたので警告しない
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA), snap(treeB)]))
    }

    // MARK: - shouldWarn: 観測が0件 → 黙る

    func testShouldWarnIsFalseWhenThereAreNoObservations() {
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: []))
    }

    // MARK: - treesAreIdentical(shouldWarn の下敷き)

    func testTreesAreIdenticalMatchesOnFingerprintNotIdentity() {
        // 同じ内容から作った別々の配列でも、指紋が同じなら同一と判定する
        XCTAssertTrue(BackEffect.treesAreIdentical(before: [element(label: "A")],
                                                    after: [element(label: "A")]))
        XCTAssertFalse(BackEffect.treesAreIdentical(before: treeA, after: treeB))
    }

    func testEmptyTreesAreIdenticalToEachOther() {
        XCTAssertTrue(BackEffect.treesAreIdentical(before: screenA, after: screenA))
    }

    // MARK: - 文言: MCP/DSL で末尾だけ違う中核文を共有する

    func testNoteSharesTheCoreSummaryAcrossCallers() {
        let mcpText = BackEffect.note(advice: BackEffect.mcpAdvice)
        let dslText = BackEffect.note(advice: BackEffect.dslAdvice)
        XCTAssertTrue(mcpText.hasPrefix(BackEffect.summary))
        XCTAssertTrue(dslText.hasPrefix(BackEffect.summary))
        XCTAssertNotEqual(mcpText, dslText)
        XCTAssertTrue(mcpText.contains("send back again"))
        XCTAssertTrue(dslText.contains("call back() again"))
    }

    /// **キーボードを閉じただけの back は「効いた」**(キーボードはアプリの木の外。Android の back は最初にキーボードだけを閉じる)。
    /// 数えないと「効かなかった・もう一度 back を」と言い、従うと2回目で画面まで戻る
    func testClosingTheKeyboardCountsAsAnEffect() {
        let keyboard = FTRect(x: 0, y: 1541, width: 1080, height: 799)
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA, keyboard: keyboard), afterObservations: [snap(treeA)]))
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA, keyboard: keyboard),
                                            afterObservations: [snap(treeA, keyboard: keyboard)]))
        // 画面の外の矩形(隠れたキーボード)は「出ていない」と同じ
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA),
                                            afterObservations: [snap(treeA, keyboard: FTRect(x: 0, y: 2400, width: 1080, height: 799))]))
    }
}
