// 同じ矩形に「位置に依存しない書き方」がある無ラベル clickable を注記から外す(2026-08-13)。
//
// iOS の設定アプリは行を clickable の容器で包み、その中に同じ矩形の button + #id を置く。
// 素の判定では容器が「ラベルも id も無い」に該当し、ホーム画面で11件・一般で20件が
// 「安定したセレクタで指せない」と報告されていた。実際には同じ矩形に
// #com.apple.settings.general があり、注記が勧める索引付きスコープ記法
// (兄弟の数で壊れる)より明らかに良い書き方が存在していた = 注記の前提が偽。

import XCTest
import FTCore
@testable import ftester_mcp

final class UnlabeledClickableTwinTests: XCTestCase {

    /// **depth を渡せること**(2026-08-13 のレビュー指摘): 全要素を depth 1 に置くと
    /// 祖先が存在せず `uniqueScopeElement` が nil になるため、**索引付きスコープ記法が
    /// 一度も生成されない** —— `.stable` 限定を守るはずのテストが素通りしていた
    /// (レビューの変異で「`graded != nil` に緩めても4本とも緑」と実証された)。
    /// 容器は depth 1、その中身は depth 2 に置く
    private func element(ref: Int, type: String, id: String? = nil, label: String? = nil,
                         x: Double = 16, y: Double = 100,
                         w: Double = 370, h: Double = 52, depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    /// **本命**: 同じ矩形に `#id` 付きの要素が居るなら黙る(そちらを書けばよい)
    func testStableTwinAtTheSameFrameSuppressesTheWarning() {
        let note = MCPServer.unlabeledClickablesNote(snapshot([
            element(ref: 1, type: "clickable"),
            element(ref: 2, type: "button", id: "com.apple.settings.general", label: "一般"),
        ]))
        XCTAssertEqual(note, "", "同じ矩形に #id があるのに「指せない」と言った: \(note)")
    }

    /// 矩形が違う twin は代替にならない(隣の行のセレクタで代用させない)
    func testATwinAtADifferentFrameDoesNotSuppress() {
        let note = MCPServer.unlabeledClickablesNote(snapshot([
            element(ref: 1, type: "clickable", y: 100),
            element(ref: 2, type: "button", id: "other", label: "別の行", y: 200),
        ]))
        XCTAssertTrue(note.contains("[1]"), note)
    }

    /// **自分自身を twin にしない**(2026-08-13 に実装で踏んだ): `selector(for:)` は索引付きの
    /// スコープ記法も返すので、素で使うと無ラベル clickable 自身が「書ける」に該当して黙る。
    /// 索引記法しか無い群では注記が出続けること
    func testAnIndexedOnlyClickableStillWarns() {
        let note = MCPServer.unlabeledClickablesNote(snapshot([
            element(ref: 1, type: "collectionView", id: "list", x: 0, y: 0, w: 402, h: 874, depth: 1),
            element(ref: 2, type: "clickable", y: 100),
            element(ref: 3, type: "clickable", y: 160),
        ]))
        XCTAssertTrue(note.contains("2 clickable element(s)"),
                      "索引記法しか無いのに黙った(自分自身を代替と数えている): \(note)")
    }

    /// 同じ矩形でも、代替が**索引付き**なら黙らない(良い書き方が無いのは事実なので)
    func testAnIndexedTwinDoesNotSuppress() {
        let note = MCPServer.unlabeledClickablesNote(snapshot([
            element(ref: 1, type: "collectionView", id: "list", x: 0, y: 0, w: 402, h: 874, depth: 1),
            element(ref: 2, type: "clickable", y: 100),
            element(ref: 3, type: "image", y: 100),
        ]))
        XCTAssertTrue(note.contains("[2]"), note)
    }

    /// **注記が出ない画面で grade を払わないこと**(2026-08-13 のレビュー指摘)。
    /// 木の全要素を無条件に grade していたため、**1バイトも出ない画面で最も高くついていた**
    /// (実測: 233 要素で 3497ms。ft_snapshot 全体が 203 要素で 1.2 秒なので桁で効く)。
    /// 正しさでは差が出ない最適化なので、**計算回数そのもの**を固定する
    func testNoGradingIsPaidOnScreensWithoutUnlabeledClickables() {
        let cache = MCPServer.SnapshotAnnotationCache()
        let dense = (1...60).map {
            element(ref: $0, type: "button", id: "btn_\($0)", label: "行 \($0)",
                    y: Double($0) * 12)
        }
        let note = MCPServer.unlabeledClickablesNote(snapshot(dense), cache: cache)

        XCTAssertEqual(note, "")
        XCTAssertEqual(cache.gradedComputeCount, 0,
                       "候補が1件も無いのに grade を払っている(注記が出ない画面ほど高くつく形)")
    }

    /// 候補があるときも、**払うのは候補と同じ矩形の要素だけ**
    func testGradingIsLimitedToFramesThatCollideWithACandidate() {
        let cache = MCPServer.SnapshotAnnotationCache()
        var elements = [element(ref: 1, type: "clickable", y: 100),
                        element(ref: 2, type: "button", id: "row", label: "行", y: 100)]
        elements += (3...50).map {
            element(ref: $0, type: "staticText", label: "他 \($0)", y: Double($0) * 12 + 300)
        }
        _ = MCPServer.unlabeledClickablesNote(snapshot(elements), cache: cache)

        XCTAssertLessThanOrEqual(cache.gradedComputeCount, 2,
                                 "候補と無関係な要素まで grade している"
                                 + "(実測 \(cache.gradedComputeCount) 回 / 候補の矩形は1つ)")
    }
}
