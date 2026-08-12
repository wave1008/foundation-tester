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

    private func element(ref: Int, type: String, id: String? = nil, label: String? = nil,
                         x: Double = 16, y: Double = 100,
                         w: Double = 370, h: Double = 52) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
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
            element(ref: 1, type: "collectionView", id: "list", x: 0, y: 0, w: 402, h: 874),
            element(ref: 2, type: "clickable", y: 100),
            element(ref: 3, type: "clickable", y: 160),
        ]))
        XCTAssertTrue(note.contains("2 clickable element(s)"),
                      "索引記法しか無いのに黙った(自分自身を代替と数えている): \(note)")
    }

    /// 同じ矩形でも、代替が**索引付き**なら黙らない(良い書き方が無いのは事実なので)
    func testAnIndexedTwinDoesNotSuppress() {
        let note = MCPServer.unlabeledClickablesNote(snapshot([
            element(ref: 1, type: "collectionView", id: "list", x: 0, y: 0, w: 402, h: 874),
            element(ref: 2, type: "clickable", y: 100),
            element(ref: 3, type: "image", y: 100),
        ]))
        XCTAssertTrue(note.contains("[2]"), note)
    }
}
