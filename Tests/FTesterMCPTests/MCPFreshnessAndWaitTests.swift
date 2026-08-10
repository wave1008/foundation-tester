// ft_screenshot の鮮度チェック(treeFingerprint)・waitFor の部分一致検出(案B: 満額待つ)・
// notationHint の記法形違い助言(endsWith/startsWith → contains)をまとめて検証する。
// いずれもデバイスに触れない純粋ロジック(指紋・文言組み立て)だけを対象にする。

import XCTest
import FTCore
import FTDSL
@testable import ftester_mcp

private func testElement(ref: Int = 1, type: String = "staticText", identifier: String? = nil,
                         label: String? = "ログイン",
                         frame: FTRect = FTRect(x: 10, y: 20, width: 100, height: 40)) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: identifier, label: label, value: nil,
               placeholder: nil, enabled: true, frame: frame, depth: 1)
}

private func testSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: 0)
}

// MARK: - 変更1: treeFingerprint

final class MCPTreeFingerprintTests: XCTestCase {

    /// 同一内容なら同じ指紋(誤検知0の前提)
    func testSameSnapshotContentProducesTheSameFingerprint() {
        let a = testSnapshot([testElement()])
        let b = testSnapshot([testElement()])
        XCTAssertEqual(MCPServer.treeFingerprint(a), MCPServer.treeFingerprint(b))
    }

    /// frame が動けば指紋も変わる
    func testAMovedFrameChangesTheFingerprint() {
        let a = testSnapshot([testElement()])
        let b = testSnapshot([testElement(frame: FTRect(x: 10, y: 60, width: 100, height: 40))])
        XCTAssertNotEqual(MCPServer.treeFingerprint(a), MCPServer.treeFingerprint(b))
    }

    /// label が変われば指紋も変わる
    func testAChangedLabelChangesTheFingerprint() {
        let a = testSnapshot([testElement(label: "ログイン")])
        let b = testSnapshot([testElement(label: "サインイン")])
        XCTAssertNotEqual(MCPServer.treeFingerprint(a), MCPServer.treeFingerprint(b))
    }

    /// 要素数が変われば指紋も変わる
    func testAnAddedElementChangesTheFingerprint() {
        let a = testSnapshot([testElement()])
        let b = testSnapshot([testElement(), testElement(ref: 2, label: "別の要素")])
        XCTAssertNotEqual(MCPServer.treeFingerprint(a), MCPServer.treeFingerprint(b))
    }

    /// **ref だけ違っても同じ木なら指紋は同じ**(2026-08-10・ref 世代管理)。
    /// MCP 層が snapshot ごとに ref へオフセットを掛けるため、同じ内容でも取得経路(native の
    /// ままか、セッション ref に振り直し済みか)によって ref 番号が変わり得る。
    /// ref を指紋に含めると同じ木を「別物」と誤検知し、ft_screenshot の鮮度警告が偽陽性になる
    func testARefOnlyChangeDoesNotChangeTheFingerprint() {
        let a = testSnapshot([testElement(ref: 1)])
        let b = testSnapshot([testElement(ref: 99)])
        XCTAssertEqual(MCPServer.treeFingerprint(a), MCPServer.treeFingerprint(b))
    }
}

// MARK: - 変更B: ft_screenshot の鮮度チェック(imageHash × treeFingerprint の前回比較。dispatch 経由)

final class MCPScreenshotFreshnessTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func hasStaleNote(_ content: [[String: Any]]) -> Bool {
        content.contains { ($0["text"] as? String)?.contains("byte-identical") == true }
    }

    /// 静止画面の2連続 ft_screenshot(木も画像も不変)は注記を足さない(誤検知0が受け入れ条件)。
    /// 応答には withElapsed の「⏱ …」テキストが常に付くので、件数ではなく中身で見る
    func testNoNoteWhenImageAndTreeAreBothUnchanged() async throws {
        _ = try await server.call(tool: "ft_screenshot", args: [:])
        let second = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertEqual(second.filter { $0["type"] as? String == "image" }.count, 1)
        XCTAssertFalse(hasStaleNote(second), "余計な注記が付いている: \(second)")
    }

    /// **B の陽性対照**: 木は変わったのに画像はバイト単位で前回と同一 → STALE 注記が出る。
    /// screenshotData は変えない(= 同じバイト列を2回返す。静止画面と同じ状況を模す)
    func testStaleNoteWhenTreeChangesButImageStaysByteIdentical() async throws {
        let first = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertFalse(hasStaleNote(first))

        driver.snapshotResponse = testSnapshot([])
        let second = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertTrue(hasStaleNote(second), "\(second)")
        XCTAssertTrue(second.contains { $0["type"] as? String == "image" }, "画像は必ず含まれること")
    }

    /// 木も画像も変わるときは注記を足さない(通常の画面遷移。imageHash が食い違うので判定式が不成立)
    func testNoNoteWhenTreeAndImageBothChange() async throws {
        _ = try await server.call(tool: "ft_screenshot", args: [:])

        driver.snapshotResponse = testSnapshot([])
        driver.scriptedScreenshots = [Data([0x01, 0x02, 0x03])]
        let second = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertFalse(hasStaleNote(second), "\(second)")
    }

    /// 木の取得に失敗 → 注記なし・screenshot 自体は従来どおり返す・記録も汚さない
    /// (次に成功したときも、失敗をまたいだ前の記録と正しく比較できることまで見る)
    func testFailedSnapshotSkipsJudgmentAndKeepsThePreviousRecordIntact() async throws {
        let first = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertFalse(hasStaleNote(first))

        driver.failing = ["snapshot"]
        let duringFailure = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertEqual(duringFailure.filter { $0["type"] as? String == "image" }.count, 1,
                       "取得失敗時も screenshot 自体は返ること")
        XCTAssertFalse(hasStaleNote(duringFailure), "取得失敗時は判定しないこと")

        // 失敗をまたいでも記録は最初の1回分のまま — 木を変え、画像は不変のまま撃つと
        // (失敗した回はカウントされずに)最初の記録と正しく比較され、陽性が出る
        driver.failing = []
        driver.snapshotResponse = testSnapshot([])
        let afterRecovery = try await server.call(tool: "ft_screenshot", args: [:])
        XCTAssertTrue(hasStaleNote(afterRecovery), "\(afterRecovery)")
    }
}

// MARK: - 変更3: waitFor の部分一致検出(案B: 満額待つ)

final class MCPWaitForPartialMatchTests: XCTestCase {

    /// 完全一致が最初の1枚に既にあれば、待たずに返す(部分一致の情報は空のまま)
    func testFullMatchInTheFirstSnapshotReturnsImmediately() async throws {
        let target = testSnapshot([testElement(identifier: "login_btn")])
        let result = try await MCPServer.waitFor("#login_btn", driver: FakeDriver(),
                                                  first: target, seconds: 5)
        XCTAssertTrue(result.found)
        XCTAssertNil(result.partialSeenAfter)
        XCTAssertEqual(result.partialHint, "")
    }

    /// 最初の1枚に部分一致だけがあるときは経過0sとして扱う
    func testPartialMatchInTheFirstSnapshotCountsAsZeroSeconds() async throws {
        let firstScreen = testSnapshot([testElement(identifier: nil, label: "総武線直通武蔵野線")])
        // seconds: 0 = 一度もポーリングせずに締め切りへ達する(タイミング非依存にするため)
        let result = try await MCPServer.waitFor("武蔵野線", driver: FakeDriver(),
                                                  first: firstScreen, seconds: 0)
        XCTAssertFalse(result.found)
        XCTAssertEqual(result.partialSeenAfter, 0)
        XCTAssertTrue(result.partialHint.contains("partial match"), result.partialHint)
    }

    /// **早期打ち切りはしない**(案B): 部分一致が途中で出ても、締め切りまでポーリングし続ける
    /// (ローディング中のプレースホルダが先に部分一致し、本命が後から来る画面があるため)
    func testWaitRunsToTheDeadlineEvenAfterAPartialMatchAppears() async throws {
        let driver = FakeDriver()
        let partial = testSnapshot([testElement(identifier: nil, label: "総武線直通武蔵野線")])
        let empty = testSnapshot([])
        driver.scriptedSnapshots = [partial, empty]

        let start = Date()
        let result = try await MCPServer.waitFor("武蔵野線", driver: driver,
                                                  first: empty, seconds: 0.5)
        XCTAssertFalse(result.found)
        XCTAssertNotNil(result.partialSeenAfter)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5,
                                    "部分一致が出てもタイムアウトまで待つこと")
    }

    /// 一度見つけたヒントは以後再計算しない(最初に見えた時点の経過秒のまま)
    func testThePartialHintIsCapturedOnlyOnce() async throws {
        let driver = FakeDriver()
        let partial = testSnapshot([testElement(identifier: nil, label: "総武線直通武蔵野線")])
        let stillPartial = testSnapshot([testElement(identifier: nil, label: "総武線直通武蔵野線")])
        driver.scriptedSnapshots = [partial, stillPartial]

        let result = try await MCPServer.waitFor("武蔵野線", driver: driver,
                                                  first: testSnapshot([]), seconds: 0.5)
        XCTAssertFalse(result.found)
        // 2枚とも同じ部分一致を出すが、記録されるのは最初に見えた1回分だけ
        XCTAssertNotNil(result.partialSeenAfter)
        XCTAssertFalse(result.partialHint.isEmpty)
    }
}

// MARK: - 変更4: notationHint の記法形違い助言(endsWith/startsWith → contains)

final class MCPPartialMatchFormHintTests: XCTestCase {

    /// 実測(2026-08-10): `*武蔵野線`(endsWith)を渡して7スクロール空振りした
    /// (正解は `*武蔵野線*`)
    func testEndsWithMismatchWithAContainsHitSuggestsTheContainsForm() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "武蔵野線 直通")])
        let hint = MCPServer.notationHint("*武蔵野線", in: snapshot)
        XCTAssertTrue(hint.contains("ends-with"), hint)
        XCTAssertTrue(hint.contains("\"*武蔵野線*\""), hint)
    }

    /// startsWith も対称に助言する
    func testStartsWithMismatchWithAContainsHitSuggestsTheContainsForm() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "直通 武蔵野線")])
        let hint = MCPServer.notationHint("武蔵野線*", in: snapshot)
        XCTAssertTrue(hint.contains("starts-with"), hint)
        XCTAssertTrue(hint.contains("\"*武蔵野線*\""), hint)
    }

    /// id にも同じ助言が出る(記法は `#*id*` であって `*id*` ではない)。
    /// id は先頭にも末尾にも一致しない(中間に含む)形で用意する ——
    /// 先頭/末尾で一致してしまうと endsWith 自体が的中し、この助言の出番が無くなる
    func testIdEndsWithMismatchSuggestsTheIdContainsForm() {
        let snapshot = testSnapshot(
            [testElement(identifier: "row_musashino_line_button", label: nil)])
        let hint = MCPServer.notationHint("#*musashino_line", in: snapshot)
        XCTAssertTrue(hint.contains("ends-with"), hint)
        XCTAssertTrue(hint.contains("\"#*musashino_line*\""), hint)
    }

    /// **既に contains 形を渡している相手には出さない**(誤って同じものを勧め返さない)
    func testAlreadyContainsFormGetsNoHint() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "武蔵野線 直通")])
        XCTAssertNil(MCPServer.partialMatchFormHint(
            FTSelector.parse("*武蔵野線*").primary, in: snapshot.elements))
    }

    /// endsWith が実際に当たっているときは黙る(誤検知しない)
    func testEndsWithThatAlreadyMatchesGetsNoHint() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "直通武蔵野線")])
        XCTAssertNil(MCPServer.partialMatchFormHint(
            FTSelector.parse("*武蔵野線").primary, in: snapshot.elements))
    }

    /// contains ですら当たらない(何にも当たらない)ときは黙る
    func testNothingMatchesAtAllGetsNoHint() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "別の路線")])
        XCTAssertNil(MCPServer.partialMatchFormHint(
            FTSelector.parse("*武蔵野線").primary, in: snapshot.elements))
    }

    /// 素の完全一致指定(記法無し)には無関係(既存の StepExecutor.partialMatchHint の担当)
    func testExactModeLocatorGetsNoFormHint() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "武蔵野線 直通")])
        XCTAssertNil(MCPServer.partialMatchFormHint(
            FTSelector.parse("武蔵野線").primary, in: snapshot.elements))
    }
}

// MARK: - 変更5: waitFor 空振り時の近傍ラベルのヒント(2026-08-10)

final class MCPSimilarLabelsHintTests: XCTestCase {

    /// 実例: 経路ボタンを `waitFor "経路"` と推測したら実ラベルは「計画」だった
    /// (どちらも部分文字列関係は無いが、短い語同士で編集距離2)
    func testSimilarLabelsHintNamesANearbyLabel() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "計画")])
        let hint = MCPServer.similarLabelsHint("経路", in: snapshot)
        XCTAssertTrue(hint.contains("similar labels on screen"), hint)
        XCTAssertTrue(hint.contains("\"計画\""), hint)
    }

    /// 部分文字列関係(大文字小文字無視)でも拾う
    func testSimilarLabelsHintCatchesASubstringRelationship() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "Sign In Button")])
        let hint = MCPServer.similarLabelsHint("sign in", in: snapshot)
        XCTAssertTrue(hint.contains("\"Sign In Button\""), hint)
    }

    /// id も候補にする(# 付きで示す)
    func testSimilarLabelsHintAlsoConsidersIdentifiers() {
        let snapshot = testSnapshot([testElement(identifier: "btn_keikaku", label: nil)])
        let hint = MCPServer.similarLabelsHint("keikaku", in: snapshot)
        XCTAssertTrue(hint.contains("#btn_keikaku"), hint)
    }

    /// 似た物が何も無ければ黙る(断定的な誤誘導を避ける)。
    /// **2文字同士は避ける**: 全く違う2文字語でも編集距離は高々2になり(2文字とも置換すれば
    /// 済むため)、どの組でも「近い」判定に入ってしまう —— これは仕様どおりの挙動
    /// (「経路」/「計画」の実例がまさにこの境界)なので、無関係の確認には十分に離れた語を使う
    func testSimilarLabelsHintStaysQuietWithNoCandidate() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "設定確認画面")])
        XCTAssertEqual(MCPServer.similarLabelsHint("経路", in: snapshot), "")
    }

    /// 完全一致なら「似ている」ではなく本人 —— 空振りの原因はここではないので黙る
    /// (waitFor 自体は先に一致判定で成功しているはずだが、関数単体としても壊れないこと)
    func testSimilarLabelsHintIgnoresAnExactMatch() {
        let snapshot = testSnapshot([testElement(identifier: nil, label: "経路")])
        XCTAssertEqual(MCPServer.similarLabelsHint("経路", in: snapshot), "")
    }

    /// 最大3件までに切る
    func testSimilarLabelsHintCapsAtThreeCandidates() {
        let snapshot = testSnapshot(
            ["計画", "経画", "経路A", "経路B"].enumerated().map { index, label in
                testElement(ref: index + 1, identifier: nil, label: label)
            })
        let hint = MCPServer.similarLabelsHint("経路", in: snapshot)
        XCTAssertEqual(hint.components(separatedBy: "\"").count - 1, 6, hint) // 3件 ×2引用符
    }

    // MARK: - isSimilarText / editDistance(純粋関数)

    func testIsSimilarTextMatchesSubstringEitherDirection() {
        XCTAssertTrue(MCPServer.isSimilarText("sign in", "Sign In Button"))
        XCTAssertTrue(MCPServer.isSimilarText("Sign In Button", "sign in"))
    }

    func testIsSimilarTextMatchesShortEditDistance() {
        XCTAssertTrue(MCPServer.isSimilarText("経路", "計画"))
        // **2文字同士は避ける**: 全く違う2文字語でも編集距離は高々2(両方置換すれば済む)なので
        // どの組でも真になる —— それ自体が「経路」/「計画」の実例が成立する理由でもある。
        // 無関係の確認には長さの違う語を使う(編集距離が6まで開く)
        XCTAssertFalse(MCPServer.isSimilarText("経路", "設定確認画面"))
    }

    /// 6文字を超える語は編集距離では拾わない(部分文字列関係が無い限り無関係とみなす)
    func testIsSimilarTextDoesNotApplyEditDistanceToLongStrings() {
        XCTAssertFalse(MCPServer.isSimilarText("abcdefg", "abcdefx"))
    }

    func testIsSimilarTextRejectsIdenticalStrings() {
        XCTAssertFalse(MCPServer.isSimilarText("経路", "経路"))
    }

    func testEditDistanceKnownValues() {
        XCTAssertEqual(MCPServer.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(MCPServer.editDistance("", "abc"), 3)
        XCTAssertEqual(MCPServer.editDistance("abc", ""), 3)
        XCTAssertEqual(MCPServer.editDistance("abc", "abc"), 0)
    }
}
