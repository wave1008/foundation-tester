// 比較前の正規化の**契約表**(2026-08-09 のユーザー決定)。
//
//   セレクタでフィルタする … 見つけたい。両端トリム・空白の種類を吸収・連続を畳む
//   テキストを期待値と比較 … 確かめたい。「見た目が完全に一致していれば同じ」
//   strict                 … 一切正規化しない(引数で明示したときだけ)
//
// **この表がズレると、同じ画面について経路ごとに答えが変わる**。実際 2026-08-09 まで
// アサーション側は正規化ゼロで、セレクタ側だけがゼロ幅を吸収していた(ゼロ幅1文字で
// textIs が落ちるのに、同じ文字列のセレクタは当たる、という状態)。

import XCTest
@testable import FTCore

final class TextNormalizationTests: XCTestCase {

    private func selector(_ a: String, _ b: String) -> Bool {
        FlowMatchMode.exact.matches(a, b, normalization: .selector)
    }
    private func text(_ a: String, _ b: String) -> Bool {
        StepExecutor.matchedText(a, expected: b, assert: "textEquals", normalization: .text) != nil
    }
    private func strict(_ a: String, _ b: String) -> Bool {
        StepExecutor.matchedText(a, expected: b, assert: "textEquals", normalization: .strict) != nil
    }

    // MARK: - 不可視文字は両モードで無視する(見た目が変わらないから)

    /// 単独で立つ書式・制御文字。**列挙で持っていない**(Cf/Cc のクラスタを落とす規則)ので、
    /// ここに無い文字にも同じ扱いが効く
    func testStandaloneInvisiblesAreIgnoredByBothModes() {
        for (name, ch) in [("ZWSP", "\u{200B}"), ("BOM", "\u{FEFF}"), ("WJ", "\u{2060}"),
                           ("SOFT HYPHEN", "\u{00AD}"), ("LRM", "\u{200E}"), ("RLM", "\u{200F}"),
                           ("LRE", "\u{202A}"), ("PDF", "\u{202C}"), ("LRI", "\u{2066}"),
                           ("ALM", "\u{061C}"), ("MVS", "\u{180E}"), ("C0", "\u{0001}")] {
            XCTAssertTrue(selector("A\(ch)B", "AB"), "\(name): セレクタで無視されていない")
            XCTAssertTrue(text("A\(ch)B", "AB"), "\(name): テキスト比較で無視されていない")
            XCTAssertFalse(strict("A\(ch)B", "AB"), "\(name): strict が正規化している")
        }
    }

    // MARK: - 書記素クラスタ内の制御文字は残す(見た目が変わるから)

    /// **消すと 👨‍👩‍👦 が 👨👩👦 になる**。④(不可視文字を消す)より③(クラスタで比較)が優先
    func testJoinersInsideAClusterAreKept() {
        XCTAssertFalse(selector("👨\u{200D}👩", "👨👩"))
        XCTAssertFalse(text("👨\u{200D}👩", "👨👩"))
    }

    /// 異体字セレクタも残す(❤ と ❤️ は別の見た目)。**末尾でも落とさない** ——
    /// 直前の文字の見え方を変えるので、繋ぐ相手が要らない
    func testVariationSelectorsAreKeptEvenAtTheEnd() {
        XCTAssertFalse(selector("❤\u{FE0F}", "❤"))
        XCTAssertFalse(text("❤\u{FE0F}", "❤"))
    }

    /// **末尾に余った結合子は落とす**(実データ: Google マップの `"…中央線\u{200D}\u{FEFF}"`)。
    /// 繋ぐ相手が居ないので見た目は変わらず、残すと目視で同一の文字列が一致しない
    func testDanglingJoinerIsDropped() {
        XCTAssertTrue(selector("中央線\u{200D}", "中央線"))
        XCTAssertTrue(text("中央線\u{200D}", "中央線"))
        XCTAssertTrue(text("中央線\u{200C}", "中央線"))
        // 繋いでいる ZWJ は落とさない(上のテストと合わせて両方向)
        XCTAssertFalse(text("👨\u{200D}👩", "👨👩"))
    }

    // MARK: - 空白: セレクタは吸収する / テキスト比較は見た目どおり

    func testWhitespaceIsAbsorbedForSelectorsOnly() {
        // NBSP は半角と同じ見た目なので**両モードで**同一視する
        XCTAssertTrue(selector("A\u{00A0}B", "A B"))
        XCTAssertTrue(text("A\u{00A0}B", "A B"))
        // 幅の違う空白は「見た目が違う」= テキスト比較では別物
        for (name, ch) in [("全角", "\u{3000}"), ("thin space", "\u{2009}"),
                           ("narrow NBSP", "\u{202F}"), ("tab", "\t")] {
            XCTAssertTrue(selector("A\(ch)B", "A B"), "\(name): セレクタで吸収されていない")
            XCTAssertFalse(text("A\(ch)B", "A B"), "\(name): テキスト比較で同一視している")
        }
    }

    /// **NEL(U+0085)は制御文字だが空白**(Unicode の White_Space)。改行なので見た目に効く ——
    /// 消さずに、セレクタ側だけ空白として寄せる。列挙ではなく性質で判定しているので、
    /// 垂直タブ・改頁・U+2028/2029 も同じ扱いになる
    func testControlCharactersThatAreWhitespaceAreFoldedNotDeleted() {
        XCTAssertTrue(selector("A\u{0085}B", "A B"))
        XCTAssertFalse(text("A\u{0085}B", "AB"), "空白を消してはいけない(見た目が変わる)")
    }

    func testRunsAreCollapsedAndEndsTrimmedForSelectorsOnly() {
        XCTAssertTrue(selector("A  B", "A B"))
        XCTAssertFalse(text("A  B", "A B"))
        XCTAssertTrue(selector("  埼京線  ", "埼京線"))
        XCTAssertFalse(text("  埼京線  ", "埼京線"))
    }

    /// 実データそのもの(Google マップ Android の路線ラベル)。
    /// **印字を写したセレクタが当たる**のがこの一連の目的
    func testRealWorldRouteLabel() {
        let raw = "\u{00A0} 埼京線"
        XCTAssertEqual(FlowMatchMode.normalizeInvisibleCharacters(raw), "  埼京線")
        XCTAssertTrue(selector(raw, "  埼京線"), "印字をそのまま写して当たること")
        XCTAssertTrue(selector(raw, "埼京線"), "トリムして写しても当たること")
    }

    // MARK: - 正準等価(Swift の String 比較が持つ性質。strict でも効く)

    func testCanonicalEquivalenceHoldsInEveryMode() {
        XCTAssertTrue(selector("é", "e\u{0301}"))
        XCTAssertTrue(text("é", "e\u{0301}"))
        XCTAssertTrue(strict("é", "e\u{0301}"))
    }

    // MARK: - 失敗メッセージ(どちらの規則なら一致したか)

    /// **normal ○ / strict × のときは打ち手まで言う**(strict を外すか期待値を直すか)
    func testVerdictNamesTheModeThatWouldMatch() {
        let verdict = StepExecutor.normalizationVerdict(
            actual: "A\u{200B}B", expected: "AB", assert: "textEquals")
        XCTAssertTrue(verdict.contains("normalized comparison: matches"), verdict)
        XCTAssertTrue(verdict.contains("strict comparison: does not match"), verdict)
        XCTAssertTrue(verdict.contains("drop strict: true"), verdict)
    }

    /// 本当に違う文字列なら**両方 ×** と言う(「正規化のせいかも」と読ませない)
    func testVerdictSaysWhenNeitherModeMatches() {
        let verdict = StepExecutor.normalizationVerdict(
            actual: "中央線", expected: "中央本線", assert: "textEquals")
        XCTAssertTrue(verdict.contains("normalized comparison: does not match"), verdict)
        XCTAssertTrue(verdict.contains("strict comparison: does not match"), verdict)
        XCTAssertFalse(verdict.contains("drop strict: true"), verdict)
    }

    /// `strict: true` は FlowStep 経由で executor へ届く(DSL の引数がここに落ちる)
    func testStrictFlagSelectsTheStrictMode() {
        var step = FlowStep(assert: "textEquals")
        XCTAssertEqual(StepExecutor.textNormalization(for: step), .text)
        step.strictText = true
        XCTAssertEqual(StepExecutor.textNormalization(for: step), .strict)
    }
}

/// **配線そのもの**を executor 経由で固定する(2026-08-09 の変異テストで必要と分かった)。
/// `matchedText` を直接呼ぶテストは、`executeAssertTextComparison` が正規化を渡さなくなっても
/// 素通しする —— 実際に「アサーションを正規化なしに戻す」変異が検出できなかった。
final class TextNormalizationWiringTests: XCTestCase {

    /// snapshot だけ返せば足りる最小ドライバ
    private final class OneScreenDriver: AppDriver {
        let elements: [ElementInfo]
        init(_ elements: [ElementInfo]) { self.elements = elements }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func terminate() async throws {}
        func screenshot() async throws -> Data { Data() }
        func type(ref: Int?, text: String) async throws {}
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                   path: FTSwipePath?) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                             screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: elements, truncatedCount: 0)
        }
    }

    /// ラベルにゼロ幅が紛れた実データ相当の画面
    private func executor() -> StepExecutor {
        let element = ElementInfo(ref: 1, type: "staticText", identifier: "fare",
                                  label: "\u{200B}715円", value: nil, placeholder: nil,
                                  enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 50, height: 20), depth: 1)
        return StepExecutor(driver: OneScreenDriver([element]))
    }

    private func step(strict: Bool?) -> FlowStep {
        var s = FlowStep(assert: "textEquals", locator: FlowLocator(id: "fare"),
                         expected: "715円", timeout: 0)
        s.strictText = strict
        s.occlusionGuard = false
        return s
    }

    /// 既定は正規化される = 見えないゼロ幅で落ちない
    func testAssertionPassesThroughNormalizationByDefault() async {
        let outcome = await executor().execute(step(strict: nil))
        guard case .passed = outcome.status else {
            return XCTFail("既定のアサーションが正規化を通っていない: \(outcome.status)")
        }
    }

    /// `strict: true` は executor まで届き、**同じ画面で落ちる**(逆方向)
    func testStrictAssertionFailsOnTheSameScreen() async {
        let outcome = await executor().execute(step(strict: true))
        guard case .failed(let reason) = outcome.status else {
            return XCTFail("strict が届いていない: \(outcome.status)")
        }
        // 失敗文が**どちらの規則なら一致したか**を言うこと(ここも実経路で確かめる)
        XCTAssertTrue(reason.contains("normalized comparison: matches"), reason)
        XCTAssertTrue(reason.contains("strict comparison: does not match"), reason)
        XCTAssertTrue(reason.contains("drop strict: true"), reason)
    }
}

/// **経路を割らない**: 肯定・否定・空判定・id が同じ正規化を通ること(2026-08-09)。
/// ここが割れると、同じ画面について「`textIs("x")` は通るのに `textIsNot("x")` も通る」
/// という矛盾した組が作れてしまう(実データにゼロ幅が1文字あるだけで起きる)。
final class NormalizationCoversEveryComparisonTests: XCTestCase {

    private let zw = "715\u{200B}円"   // 見た目は "715円"

    private func negative(_ assert: String, _ actual: String, _ expected: String?,
                          _ mode: TextNormalization = .text) -> Bool {
        StepExecutor.negativeAssertSatisfied(assert, actual: actual, expected: expected,
                                             normalization: mode)
    }

    /// 肯定と否定が**同じ答え**を出す(片方だけ正規化されていない状態を止める)
    func testPositiveAndNegativeAgree() {
        let positive = StepExecutor.matchedText(zw, expected: "715円", assert: "textEquals",
                                                normalization: .text) != nil
        let negativeSatisfied = negative("textNotEquals", zw, "715円")
        XCTAssertTrue(positive, "肯定側が正規化を通っていない")
        XCTAssertFalse(negativeSatisfied, "否定側だけ素の比較 = 肯定と否定が両方成立してしまう")
    }

    /// 否定系(Contains/StartsWith/EndsWith/Matches)も正規化を通る
    func testEveryNegativeFormIsNormalised() {
        XCTAssertFalse(negative("textContainsNot", zw, "715円"))
        XCTAssertFalse(negative("textStartsWithNot", zw, "715"))
        XCTAssertFalse(negative("textEndsWithNot", zw, "円"))
        // strict では素のまま = 否定が成立する(逆方向)
        XCTAssertTrue(negative("textContainsNot", zw, "715円", .strict))
    }

    /// **ゼロ幅だけの文字列は「空」**(見た目が空だから)。strict では空でない
    func testInvisibleOnlyTextCountsAsEmpty() {
        XCTAssertTrue(negative("textIsEmpty", "\u{200B}\u{FEFF}", nil))
        XCTAssertFalse(negative("textIsNotEmpty", "\u{200B}\u{FEFF}", nil))
        XCTAssertFalse(negative("textIsEmpty", "\u{200B}\u{FEFF}", nil, .strict))
    }

    /// 空白は空ではない(見た目に幅がある)
    func testWhitespaceIsNotEmpty() {
        XCTAssertFalse(negative("textIsEmpty", " ", nil))
        XCTAssertFalse(negative("textIsEmpty", "\u{3000}", nil))
    }

    /// id も同じ正規化を通る(2026-08-09 のユーザー決定: 日本語 id が実在するため正規化する)
    func testIdIsNormalisedToo() {
        XCTAssertNotNil(StepExecutor.matchedText("btn\u{200B}_ok", expected: "btn_ok",
                                                 assert: "idEquals", normalization: .text))
        XCTAssertNil(StepExecutor.matchedText("btn\u{200B}_ok", expected: "btn_ok",
                                              assert: "idEquals", normalization: .strict))
        // 全角と半角は別物(見た目が違う)
        XCTAssertNil(StepExecutor.matchedText("ＩＤ", expected: "ID",
                                              assert: "idEquals", normalization: .text))
    }
}
