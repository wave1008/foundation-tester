import XCTest
@testable import FTAgent

/// FM の rationale は @Guide で「日本語で1文」を要求しているが、構造化出力から外れて
/// セッションのトランスクリプトを末尾へ巻き込むことがある(2026-07-22 実測)。
/// 汚れたまま修正提案の文言とヒールキャッシュの両方に永続化されるため、発生源で切り詰める。
final class HealRationaleTests: XCTestCase {

    /// 実測で観測した混入そのもの。句点までで切れること
    func testStripsTranscriptLeakAfterFirstSentence() {
        let raw = "btn_heal_v2 は「修復」を目的としたボタンであり、btn_heal_v1 と役割が同じであるため適切な代わりとなる。」} with tools:[] | 私は UI テストのロケータ修復者です。アプリの UI 変更で見つからなくな"
        XCTAssertEqual(
            FMReplayDelegate.sanitizeRationale(raw),
            "btn_heal_v2 は「修復」を目的としたボタンであり、btn_heal_v1 と役割が同じであるため適切な代わりとなる。")
    }

    /// 正常な1文はそのまま(句点を落とさない)
    func testKeepsCleanSingleSentence() {
        XCTAssertEqual(FMReplayDelegate.sanitizeRationale("同じ役割のボタンです。"), "同じ役割のボタンです。")
    }

    /// 句点が無い場合は崩れの目印で切る
    func testCutsAtMarkerWhenNoPeriod() {
        XCTAssertEqual(FMReplayDelegate.sanitizeRationale("代役として妥当」} with tools:[]"), "代役として妥当")
        XCTAssertEqual(FMReplayDelegate.sanitizeRationale("代役として妥当\n私は UI テストの"), "代役として妥当")
    }

    /// 句点も目印も無ければ長さで頭打ち(従来動作)
    func testFallsBackToLengthCap() {
        let long = String(repeating: "あ", count: 300)
        XCTAssertEqual(FMReplayDelegate.sanitizeRationale(long).count, 120)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(FMReplayDelegate.sanitizeRationale("  \n同じ役割です。  "), "同じ役割です。")
    }
}
