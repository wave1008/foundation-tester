// occlusion-guard の可否規則(FM の転写 × 期待文字列)。期待値はすべてリテラル。
// 実測(2026-09-15・ja/en 合成変種)で出た形をそのまま置く: 切り詰め・1 文字誤読・左からの覆い・
// 空白・別の文字。

import XCTest
@testable import FTCore

final class TranscriptMatchTests: XCTestCase {

    func testConstantsArePinned() {
        XCTAssertEqual(TranscriptMatch.truncatedPrefixMinimum, 2)
        XCTAssertEqual(TranscriptMatch.misreadDivisor, 5)
        XCTAssertEqual(TranscriptMatch.mostlyHiddenRatio, 0.5)
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

    /// 先頭一致の3分岐: 省略記号 → 常に緑(ellipsized)/ 比 > 0.5 → 緑(partiallyHidden)/
    /// 比 ≤ 0.5(境界含む)→ 赤(mostlyHidden)
    func testPrefixMatchSplitsByRatioAndEllipsis() {
        // 比 0.625 (5/8) > 0.5 → 緑・partiallyHidden
        let mostlyOK = TranscriptMatch.judge(transcript: "abcde", expected: "abcdefgh")
        XCTAssertTrue(mostlyOK.visible)
        XCTAssertEqual(mostlyOK.state, .partiallyHidden)

        // 比 ちょうど 0.5 (2/4) → 「以下」なので赤・mostlyHidden
        let exactlyHalf = TranscriptMatch.judge(transcript: "ab", expected: "abcd")
        XCTAssertFalse(exactlyHalf.visible)
        XCTAssertEqual(exactlyHalf.state, .mostlyHidden)

        // 比 0.25 (2/8) < 0.5 → 赤・mostlyHidden
        let mostlyHidden = TranscriptMatch.judge(transcript: "ab", expected: "abcdefgh")
        XCTAssertFalse(mostlyHidden.visible)
        XCTAssertEqual(mostlyHidden.state, .mostlyHidden)

        // 生の転写の末尾に省略記号があれば、読めたのが 1/5 でも常に緑・ellipsized
        let ellipsisDots = TranscriptMatch.judge(transcript: "a...", expected: "abcde")
        XCTAssertTrue(ellipsisDots.visible)
        XCTAssertEqual(ellipsisDots.state, .ellipsized)
        let ellipsisChar = TranscriptMatch.judge(transcript: "a…", expected: "abcde")
        XCTAssertTrue(ellipsisChar.visible)
        XCTAssertEqual(ellipsisChar.state, .ellipsized)

        // 丸ごと含む(o.contains(e))なら先頭一致の分岐より前で fullyVisible のまま
        let full = TranscriptMatch.judge(transcript: "prefix abcdefgh suffix", expected: "abcdefgh")
        XCTAssertTrue(full.visible)
        XCTAssertEqual(full.state, .fullyVisible)
    }

    /// 省略記号があるときだけ、先頭一致に誤読(読めた長さ ÷5 文字)を許す。合成で実測した読み:
    /// 長い省略で 1 文字を読み落とした形・ヒラギノの `…` を点の列で読んだ形
    func testEllipsizedPrefixToleratesMisread() {
        let expected = "ソフトウェアアップデート、デバイスの言語、CarPlay、AirDropなど、iPhoneの全体的な設定や管理を行います。"
        let dropped = TranscriptMatch.judge(
            transcript: "ソフトウェアアップデート、デバイスの言語、CarPlay、AirDropなど、iPhoneの全体な設定や自・・・",
            expected: expected)
        XCTAssertTrue(dropped.visible)
        XCTAssertEqual(dropped.state, .ellipsized)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "画面⋯•", expected: "画面表示と明るさ").state, .ellipsized)
        // 5 文字未満の読みには誤読を許さない(許容 0 = 厳密な先頭一致だけ)
        XCTAssertEqual(TranscriptMatch.judge(transcript: "7・・・", expected: "フォント").state, .textMismatch)
    }

    /// 省略記号が無いときは先頭一致に誤読を許さない —— 値だけ違う読みが「一部が隠れている」に化けない
    /// (同じ長さなので誤読の許容で fullyVisible。値の正しさは木が保証する)
    func testValueDifferenceWithoutEllipsisIsNotPartiallyHidden() {
        let v = TranscriptMatch.judge(transcript: "tap=3", expected: "tap=0")
        XCTAssertTrue(v.visible)
        XCTAssertEqual(v.state, .fullyVisible)
    }

    func testApproximatePrefixLength() {
        XCTAssertEqual(TranscriptMatch.approximatePrefixLength(of: "abcdxfgh", in: "abcdefghij"), 8)
        XCTAssertNil(TranscriptMatch.approximatePrefixLength(of: "abcd", in: "abcdefghij"), "4 文字は許容 0")
        XCTAssertNil(TranscriptMatch.approximatePrefixLength(of: "zzzzzzzz", in: "abcdefghij"))
        // 読みが期待より長くても落ちない(範囲の下限 > 上限)
        XCTAssertNil(TranscriptMatch.approximatePrefixLength(of: "abcdefghijklmnop", in: "abc"))
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

    /// 転写が期待と同じ長さ以上なら、先頭の文字が転写に無くても誤読の許容を当てる
    /// (実アプリのコーパスで見つかった誤った赤: 「iCloud」→「¡Cloud」)。
    /// 全角引用符は半角へ畳んでから比較する(実例: iOS 設定「"カレンダー"の新機能」)
    func testMisreadToleratedWithoutHeadMatchWhenTranscriptIsNotShorter() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "¡Cloud", expected: "iCloud").visible)
    }

    func testFullWidthQuotesFoldToHalfWidthBeforeMatching() {
        XCTAssertTrue(TranscriptMatch.judge(transcript: "\"カレンダー\"の新機能",
                                            expected: "\u{201C}カレンダー\u{201D}の新機能").visible)
    }

    /// 左からの覆いで短くなった読みは、対で相変わらず不可視(covered)のまま
    /// (誤読の許容を緩めても、短くなる形の覆いは見逃さない)
    func testShortenedByCoverageStaysInvisible() {
        XCTAssertEqual(TranscriptMatch.judge(transcript: "bout", expected: "About").state, .covered)
        XCTAssertFalse(TranscriptMatch.judge(transcript: "bout", expected: "About").visible)
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

    /// 退けた転写のうち OCR に確かめさせる「惜しい」もの: 字体の取り違え(1 文字)は該当、
    /// 空・無関係・2 文字以上ずれた短い語は該当しない
    func testNearMissCoversGlyphVariantsOnly() {
        XCTAssertTrue(TranscriptMatch.isNearMiss(transcript: "单一行", expected: "単一行"))
        XCTAssertTrue(TranscriptMatch.isNearMiss(transcript: "擴張", expected: "拡張"))
        XCTAssertTrue(TranscriptMatch.isNearMiss(transcript: "ff", expected: "Off"))   // OCR が「Off」を読めなければ覆いのまま
        XCTAssertFalse(TranscriptMatch.isNearMiss(transcript: "", expected: "拡張"))
        XCTAssertFalse(TranscriptMatch.isNearMiss(transcript: "ピン留め", expected: "概要"))
        XCTAssertFalse(TranscriptMatch.isNearMiss(transcript: "ホーム", expected: "検定"))
        // 惜しさの判定は緩い(1 文字差は全部拾う)。可否は OCR が丸ごと読めたかで決まる
        XCTAssertTrue(TranscriptMatch.isNearMiss(transcript: "検索設定", expected: "検定"))
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
