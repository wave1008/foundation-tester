// 読み返しが目標にする値の採り直し(`StepExecutor.readbackTarget`。2026-08-13)。
//
// witness: E2E-CMP の `#field_single` は空のとき value="単一行"(ヒント)を返し `placeholder` を
// 出さないので、`expected = 撃つ前の値 + 本文` が最初から偽になる。plan は必ず `.unverifiable` へ
// 落ち、**追送も打ち直しも走らないまま受理される**(読み返しの砦が丸ごと外れる)。
// 偽であることは自前の E2E が毎回証明していた —— 同じシナリオの次の行
// `textIs "#txt_echo_length" == "len=8"` が通るのに、注記は "単一行hello123"(11文字)を予告していた。

import XCTest
@testable import FTCore

final class TypeReadbackTargetTests: XCTestCase {

    /// **witness**: ヒントが value に載る欄。撃った文字だけが残っていたら目標を採り直す
    func testFallsBackToTypedTextWhenThePriorValueWasHintText() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "単一行hello123", typedOnly: "hello123",
                                        actual: "hello123"),
            "hello123")
    }

    /// 採り直した目標で**追送が復活する**(ここが本題 —— 受理されるかどうかではなく、修復が走るか)
    func testFallbackRestoresTheResendRepair() {
        let target = StepExecutor.readbackTarget(expected: "単一行hello123", typedOnly: "hello123",
                                                 actual: "hello")
        XCTAssertEqual(target, "hello123")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "hello"), .resend("123"))
        // 採り直さないと諦めていたこと(退行したら落ちる)
        XCTAssertEqual(TypeReadback.plan(expected: "単一行hello123", actual: "hello"), .unverifiable)
    }

    /// 本当に値が入っていた欄では `expected` のまま(連結は正しい)
    func testKeepsExpectedWhenThePriorValueWasReal() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "oldnew", typedOnly: "new", actual: "oldnew"),
            "oldnew")
    }

    /// **順序の砦**: 撃つ前の値と本文が同じ欄で、追記が届かなかった失敗を `.done` に見せない。
    /// `expected` の plan が修復可能(`.resend`)なので採り直さない
    func testDoesNotHideAFailedAppendWhenPriorEqualsTypedText() {
        let target = StepExecutor.readbackTarget(expected: "abcabc", typedOnly: "abc", actual: "abc")
        XCTAssertEqual(target, "abcabc")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "abc"), .resend("abc"))
    }

    /// 撃つ前が空(expected == typedOnly)なら採り直す余地が無い
    func testNoAlternativeWhenTheFieldWasEmpty() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "abc", typedOnly: "abc", actual: "ab"), "abc")
    }

    /// どちらの目標でも説明できない値(自動整形など)は `expected` のまま = 今までどおり諦める
    func testKeepsExpectedWhenNeitherTargetExplainsTheValue() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "単一行12345", typedOnly: "12345",
                                        actual: "1-2345"),
            "単一行12345")
    }

    // ---- 不可視文字の正規化(2026-08-15) ----
    // MCP 側(replaceVerificationNote/appendVerificationNote)は既に
    // FlowMatchMode.normalizeInvisibleCharacters を両辺にかけているが、DSL のこの読み返し経路だけ
    // 素の比較のままだと、見た目が同じ文字列でも不一致になり 8 秒待った末にシナリオが失敗する
    // (MCP は緑・シナリオは赤という食い違い)。readbackTarget は expected/typedOnly/actual の
    // 三者を自前で正規化するので、呼び出し側の正規化有無に関わらずここで検証できる。

    /// ゼロ幅文字が**読み返し値だけ**に混じっていても正規化後は一致として扱う。
    ///
    /// **`actual` の正規化は readbackTarget 自身がやること**を確かめる形にしてある(2026-08-15)。
    /// アサーション側で `normalizeInvisibleCharacters` を掛けてから `plan` を呼ぶ書き方だと、
    /// テストが production の代わりに正規化してしまい、**production 側の正規化を外しても落ちない**
    /// (変異で実際に生き残った)。ここは正規化していない生の値だけを渡す。
    ///
    /// この組(expected ≠ typedOnly かつ actual が typedOnly と正規化後だけ一致)を選ぶのは、
    /// **戻り値が分岐する唯一の形**だから —— actual を正規化しないと両方の plan が
    /// `.unverifiable` になり `expected` が返る(= 追記が届いていないのに全文一致を期待し続ける)
    func testTreatsInvisibleCharactersInActualAsAMatch() {
        let target = StepExecutor.readbackTarget(expected: "priorhi", typedOnly: "hi",
                                                  actual: "h\u{200B}i")
        XCTAssertEqual(target, "hi", "actual を正規化していれば typedOnly 側へ寄る")
    }

    /// 実経路(type ステップ全体)で確かめる版。`readbackTarget` 単体では
    /// `awaitTypeCommit` が読み返した値を正規化しているかを確かめられない。
    ///
    /// **不可視文字が途中にある形**(`Hel\u{200B}lo`): 正規化しないと `plan` の前方一致が
    /// どちらにも成立せず `.unverifiable` = **黙って受理**になる。ステップは緑のまま通るので、
    /// **読み返しの砦が丸ごと外れたことに誰も気付かない**(このファイル冒頭の witness と同じ型)。
    /// ここは「通ること」ではなく**検証を諦めていないこと**を見たいので、下の末尾形と対で置く
    func testTypeStepAcceptsAValueThatOnlyDiffersByInvisibleCharacters() async {
        let outcome = await runTypeStep(fieldValue: "Hel\u{200B}lo", typing: "Hello")
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "ゼロ幅文字だけの差で読み返しを失敗させてはいけない: \(outcome.status)")
    }

    /// **不可視文字が末尾にある形**(`Hello\u{200B}`): 正規化しないと `actual.hasPrefix(expected)`
    /// が成立して `.deleteExcess` へ落ち、**clearInput + 全文打ち直し**が走る。打ち直しても欄は
    /// 同じ値を返すので停滞し、最後は "did not settle" で**ステップが失敗する**(最大 8 秒)。
    /// 正規化していれば1周目で `.done`。**この形が正規化を外した変異を殺す唯一の入力**
    /// (途中形は `.unverifiable` で緑のまま通ってしまうため)
    func testTypeStepDoesNotRetypeOverATrailingInvisibleCharacter() async {
        let outcome = await runTypeStep(fieldValue: "Hello\u{200B}", typing: "Hello")
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "末尾のゼロ幅文字を「余分な入力」と読んで打ち直してはいけない: \(outcome.status)")
    }

    /// **空の欄**へ1回 type し、以後は `fieldValue` を読み返す形。
    /// 撃つ前を空にするのが肝 —— 撃つ前から値が入っていると `expected = 既存値 + 本文` になり、
    /// 検証したい「打った文字がそのまま入ったか」ではなく追記の話になる
    private func runTypeStep(fieldValue: String, typing: String) async -> StepOutcome {
        let driver = ReadbackStubDriver(before: "", after: fieldValue)
        return await StepExecutor(driver: driver).execute(
            FlowStep(action: "type", locator: FlowLocator(id: "field"), text: typing))
    }

    /// ゼロ幅文字が**期待値だけ**に混じっていても正規化後は一致として扱う
    func testTreatsInvisibleCharactersInExpectedAsAMatch() {
        let target = StepExecutor.readbackTarget(expected: "priorHel\u{200B}lo", typedOnly: "Hello",
                                                  actual: "priorHello")
        XCTAssertEqual(target, "priorHello")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "priorHello"), .done)
    }

    /// ゼロ幅の雑音を落としても、見える文字の欠落(=本当の resend 対象)は隠さない
    func testStillResendsVisibleCharactersAfterNormalizingNoise() {
        let target = StepExecutor.readbackTarget(expected: "priorHello", typedOnly: "Hello",
                                                  actual: "prio\u{200B}r")
        XCTAssertEqual(target, "priorHello")
        XCTAssertEqual(
            TypeReadback.plan(expected: target,
                              actual: FlowMatchMode.normalizeInvisibleCharacters("prio\u{200B}r")),
            .resend("Hello"))
    }

    /// **逆方向の変異ガード**: 正規化しても消えない見える文字の差分(o と p)は依然として一致にならない
    /// (「常に正規化して常に一致させる」実装への退化をここで検出する)
    func testGenuinelyDifferentValuesStillDoNotMatchAfterNormalizing() {
        let target = StepExecutor.readbackTarget(expected: "hello", typedOnly: "hello",
                                                  actual: "hell\u{200B}p")
        XCTAssertEqual(target, "hello")
        XCTAssertEqual(
            TypeReadback.plan(expected: target,
                              actual: FlowMatchMode.normalizeInvisibleCharacters("hell\u{200B}p")),
            .unverifiable)
    }
}

/// 打鍵の前後で欄の値が変わるドライバ。`verifiesTypedText` は既定 false = in-app 相当なので
/// `StepExecutor` がホスト側で読み返す経路(検証したい経路)を通る。
/// `clearInput` は**わざと何もしない** —— `.deleteExcess` へ落ちた回に打ち直しても値が変わらず
/// 停滞することで、「正規化を外すと失敗する」を観測できるようにする
private final class ReadbackStubDriver: AppDriver {
    private let before: String
    private let after: String
    private var typed = false
    init(before: String, after: String) { self.before = before; self.after = after }

    private var response: SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "textField", identifier: "field",
                                                label: nil, value: typed ? after : before,
                                                placeholder: nil, enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 100, height: 40),
                                                depth: 1)],
                         truncatedCount: 0)
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func snapshot() async throws -> SnapshotResponse { response }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws { typed = true }
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
