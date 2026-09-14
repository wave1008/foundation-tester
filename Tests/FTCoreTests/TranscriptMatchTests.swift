// occlusion-guard の可否規則(FM の転写 × 期待文字列)。期待値はすべてリテラル。
// 実測(2026-09-15・ja/en 合成変種)で出た形をそのまま置く: 切り詰め・1 文字誤読・左からの覆い・
// 空白・別の文字。

import XCTest
@testable import FTCore

final class TranscriptMatchTests: XCTestCase {

    func testConstantsArePinned() {
        XCTAssertEqual(TranscriptMatch.truncatedPrefixMinimum, 2)
        XCTAssertEqual(TranscriptMatch.misreadDivisor, 5)
    }

    func testExactAndContainedTranscriptsAreVisible() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "一般", expected: "一般").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "設定 一般 >", expected: "一般").visible)
        // 空白・全角半角・大小の違いは正規化で吸収する
        XCTAssertTrue(TranscriptMatch.judge(transcript: "no recents", expected: "No Recents").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "Ａｐｐｌｅ Account", expected: "Apple\u{a0}Account").visible)
    }

    /// 末尾の切り詰め(「家電・電化…」)は先頭が読めていれば見えている
    func testTruncatedPrefixIsVisible() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "家電・電化…", expected: "家電・電化製品").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "Language & R", expected: "Language & Region").visible)
        // 1 文字だけの一致は偶然が多すぎるので認めない
        XCTAssertFalse(TranscriptMatch.judge(transcript: "家", expected: "家電・電化製品").visible)
    }

    /// 実測の誤読: 5 文字以上なら 1 文字(÷5 切り捨て)、10 文字以上なら 2 文字まで許す
    func testSmallMisreadIsTolerated() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "最近開いた書類はこちらに表示されます。",
                                            expected: "最近開いた書類はここに表示されます。").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "ようこそリマインドラーへ", expected: "ようこそリマインダーへ").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "ユーザ辞典", expected: "ユーザ辞書").visible)
        XCTAssertTrue(TranscriptMatch.judge(transcript: "swipe=aown", expected: "swipe=down").visible)
        // 前後に文脈が混ざっていても、期待文字列に相当する区間だけで数える
        XCTAssertTrue(TranscriptMatch.judge(transcript: "設定 > ユーザ辞典 5", expected: "ユーザ辞書").visible)
        // 短い語には誤読を許さない(「検索」「検定」を同一視しない。旧字体「擴張」は残る誤った赤 1/70)
        XCTAssertFalse(TranscriptMatch.judge(transcript: "検定", expected: "検索").visible)
        XCTAssertFalse(TranscriptMatch.judge(transcript: "擴張", expected: "拡張").visible)
        // 2 文字の誤読は 10 文字未満では許さない
        XCTAssertFalse(TranscriptMatch.judge(transcript: "ユーザ辞典集", expected: "ユーザ辞書帳").visible)
    }

    /// 先頭の文字が読めていない形は誤読ではなく左からの覆い(1 文字の欠けとして通さない)
    func testMissingHeadIsNotToleratedAsMisread() {
        XCTAssertEqual(TranscriptMatch.judge(transcript: "bout", expected: "About").state, .covered)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "onts", expected: "Fonts").state, .covered)
    }

    /// 左から覆われて末尾だけ見える形は「先頭が覆われている」= 見えていない
    func testTailOnlyIsCovered() {
        let v = TranscriptMatch.judge(transcript: "ボード", expected: "キーボード")
        XCTAssertFalse(v.visible)
        XCTAssertEqual(v.state, .covered)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "ents", expected: "No Recents").state, .covered)
    }

    func testEmptyTranscriptIsNotRendered() {
        let v = TranscriptMatch.judge(transcript: "", expected: "情報")
        XCTAssertFalse(v.visible)
        XCTAssertEqual(v.state, .notRendered)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "  \n", expected: "情報").state, .notRendered)
    }

    func testUnrelatedTextIsMismatch() {
        let v = TranscriptMatch.judge(transcript: "ピン留め", expected: "概要")
        XCTAssertFalse(v.visible)
        XCTAssertEqual(v.state, .textMismatch)
        XCTAssertTrue(v.reason.contains("ピン留め"), "理由に読めた文字が無い(切り分けの鍵)")
        XCTAssertEqual(TranscriptMatch.judge(transcript: "Search", expected: "No Recents").state, .textMismatch)
        // 別の文字が期待文字列の大半の文字を含んでいても、÷5 の枠を超える差は別の文字
        XCTAssertEqual(TranscriptMatch.judge(transcript: "Siriによるウオレットの機能", expected: "ウォレットの新機能").state,
                       .textMismatch)
    }

    /// 期待側が正規化で空になる(省略記号だけ等)ときは照合できない。FM が何かを読めた以上は
    /// 描かれている側に倒す。転写も空(省略記号だけ)なら「読める文字が無い」が先に立つ
    func testEmptyExpectedFallsToVisibleWhenSomethingIsDrawn() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "abc", expected: "…").visible)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "…", expected: "…").state, .notRendered)
        XCTAssertFalse(TranscriptMatch.judge(transcript: "", expected: "…").visible)
    }

    func testApproximateSubstringDistance() {
        XCTAssertEqual(TranscriptMatch.approximateSubstringDistance(haystack: "abcdef", needle: "abcdef"), 0)
        XCTAssertEqual(TranscriptMatch.approximateSubstringDistance(haystack: "xxabcdyfxx", needle: "abcdef"), 1)
        // 挿入 1 + 置換 1(窓を固定すると 3 に膨らむ形)
        XCTAssertEqual(TranscriptMatch.approximateSubstringDistance(haystack: "ようこそリマインドラーへ", needle: "ようこそリマインダーへ"), 2)
        XCTAssertEqual(TranscriptMatch.approximateSubstringDistance(haystack: "ab", needle: "abcdef"), 4)
        XCTAssertEqual(TranscriptMatch.approximateSubstringDistance(haystack: "", needle: "abc"), 3)
    }
}
