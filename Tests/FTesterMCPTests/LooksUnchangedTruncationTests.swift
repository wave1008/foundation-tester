// looksUnchanged が要素上限の外で起きた変化(truncatedCount の増減)を見落とす件の回帰
// (2026-08-13 監査)。iOS Safari で横スクロール表のページ送りが +113 要素を追加したが、
// 全件が 120 件の cutoff より下に並んだため生存 120 行はバイト同一のまま truncatedCount だけ
// 0→113 に動き、waitForChange が「変わっていない」と誤って報告していた。
//
// 併せて、木がほぼ空のときに unchanged 系の verdict へ足す注意書き
// (MCPServer.unrepresentedScreenCaveat)のしきい値境界も確認する。算出そのもの
// (unrepresentedScreenFraction)は MCPServer+Hints.swift の実装が持つ — ここは
// **verdict 文字列に注意書きが実際に載るか**だけを見る。

import XCTest
import FTCore
@testable import ftester_mcp

// MARK: - looksUnchanged 本体(純関数。driver 不要)

private func lutElement(ref: Int, id: String? = "row", value: String? = nil,
                        frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 40)) -> ElementInfo {
    ElementInfo(ref: ref, type: "staticText", identifier: id, label: "label", value: value,
               placeholder: nil, enabled: true, frame: frame, depth: 1)
}

private func lutSnapshot(_ elements: [ElementInfo], truncatedCount: Int = 0) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: truncatedCount)
}

final class LooksUnchangedTruncationTests: XCTestCase {

    /// **回帰そのもの**: elements は1バイトも変わらず truncatedCount だけ動く
    /// (= 切り詰められた側だけで起きた変化)→ unchanged と判定してはいけない
    func testDifferentTruncatedCountIsNotUnchangedEvenWithIdenticalElements() {
        let before = lutSnapshot([lutElement(ref: 1)], truncatedCount: 0)
        let after = lutSnapshot([lutElement(ref: 1)], truncatedCount: 113)
        XCTAssertFalse(MCPServer.looksUnchanged(before, after),
                       "truncatedCount だけの変化を見落とすと画面の変化を取りこぼす")
    }

    /// 既存契約(退行させない): elements・truncatedCount がどちらも同一なら unchanged のまま
    func testIdenticalElementsAndTruncatedCountIsUnchanged() {
        let before = lutSnapshot([lutElement(ref: 1)], truncatedCount: 7)
        let after = lutSnapshot([lutElement(ref: 1)], truncatedCount: 7)
        XCTAssertTrue(MCPServer.looksUnchanged(before, after))
    }

    /// 既存の判別軸①: value の変化(truncatedCount 追加が既存の比較を弱めていないこと)
    func testDifferingValueIsNotUnchanged() {
        let before = lutSnapshot([lutElement(ref: 1, value: "old")])
        let after = lutSnapshot([lutElement(ref: 1, value: "new")])
        XCTAssertFalse(MCPServer.looksUnchanged(before, after))
    }

    /// 既存の判別軸②: frame の変化(スクロール等)
    func testDifferingFrameIsNotUnchanged() {
        let before = lutSnapshot([lutElement(ref: 1,
                                             frame: FTRect(x: 0, y: 0, width: 100, height: 40))])
        let after = lutSnapshot([lutElement(ref: 1,
                                            frame: FTRect(x: 0, y: 200, width: 100, height: 40))])
        XCTAssertFalse(MCPServer.looksUnchanged(before, after))
    }

    /// 既存の判別軸③: 要素数そのものの変化
    func testDifferingElementCountIsNotUnchanged() {
        let before = lutSnapshot([lutElement(ref: 1)])
        let after = lutSnapshot([lutElement(ref: 1), lutElement(ref: 2, id: "row2")])
        XCTAssertFalse(MCPServer.looksUnchanged(before, after))
    }
}

// MARK: - unrepresentedScreenCaveat のしきい値境界(FakeDriver 経由)
//
// settle-lite(snapshotAfterBodyWithStatus)が最短で verdict 文字列に到達できる経路
// (testWithoutWaitForSettleLiteStillRuns と同じ形)。waitForChange/waitFor/ft_batch は
// 同じ MCPServer.unrepresentedScreenCaveat を再利用しているだけなので、ここでは二重に確認しない

private func bandElement(y: Double, height: Double) -> ElementInfo {
    ElementInfo(ref: Int(y), type: "staticText", identifier: "band-\(Int(y))", label: nil,
               value: nil, placeholder: nil, enabled: true,
               frame: FTRect(x: 0, y: y, width: 390, height: height), depth: 1)
}

private let bandScreen = FTRect(x: 0, y: 0, width: 390, height: 844)

final class UnrepresentedScreenCaveatBoundaryTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// 覆っているのは画面のごく一部(小さな1要素)→ 最大の空帯が画面の過半を占める
    /// (>= unrepresentedScreenCaveatThreshold = 0.5)→ 注意書きが出る
    func testCaveatFiresWhenMostOfTheScreenIsUnrepresented() async throws {
        let sparse = SnapshotResponse(sessionBundleID: "com.example.app", screen: bandScreen,
                                      elements: [bandElement(y: 20, height: 40)], truncatedCount: 0)
        driver.scriptedSnapshots = [sparse, sparse, sparse]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("still looked unchanged"), text)
        XCTAssertTrue(text.contains("no element in the tree at all"), text)
        XCTAssertTrue(text.contains("ft_screenshot"), text)
    }

    /// 画面のほとんどを要素が覆っている(空帯は最大でも 50/844 ≈ 6% しか無い)→ しきい値未満 = 黙る
    func testCaveatIsSilentWhenTheScreenIsWellRepresented() async throws {
        let dense = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: bandScreen,
            elements: [bandElement(y: 0, height: 300), bandElement(y: 350, height: 300),
                      bandElement(y: 700, height: 144)],
            truncatedCount: 0)
        driver.scriptedSnapshots = [dense, dense, dense]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("still looked unchanged"), text)
        XCTAssertFalse(text.contains("no element in the tree at all"), text)
    }

    // **呼び出し口ごとに1本ずつ要る**: unrepresentedScreenCaveat 自体の境界を
    // 上の2本が押さえていても、**各 verdict への連結を消す変異は全部生き残った**
    // (settle-lite 以外の3口 = waitFor 節・waitForChange タイムアウト・ft_batch)。
    // 判定を1本に寄せても、配線は寄らない。ft_batch 側は MCPBatchUnchangedNoteTests

    /// waitFor が空振りし、かつ木が操作前と同一 → 「action itself may not have taken effect」に添う
    func testCaveatIsAppendedToTheWaitForIdenticalTreeClause() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: bandScreen,
            elements: [bandElement(y: 20, height: 40)], truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap",
            args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                   "waitFor": "#never-appears", "timeout": 0.01]))
        XCTAssertTrue(text.contains("may not have taken effect"), text)
        XCTAssertTrue(text.contains("no element in the tree at all"), text)
    }

    /// waitForChange が期限切れ → 「may not have changed the screen」に添う
    func testCaveatIsAppendedToTheWaitForChangeTimeout() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: bandScreen,
            elements: [bandElement(y: 20, height: 40)], truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap",
            args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                   "waitForChange": true, "timeout": 0.01]))
        XCTAssertTrue(text.contains("waitForChange timed out"), text)
        XCTAssertTrue(text.contains("no element in the tree at all"), text)
    }
}
