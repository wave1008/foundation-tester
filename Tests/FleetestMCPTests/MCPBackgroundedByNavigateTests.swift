// `ft_navigate home` / `appSwitcher` のあと、木が前のアプリのままであることを言い続ける配線。
//
// 動機(2026-09-01・実機 iPhone 13 の探索): appSwitcher を送ると注記ゼロで、続く ft_snapshot は
// 直前のアプリの木をそのまま返し、その ref への ft_tap も無警告で done を返した(実際には
// ホーム画面を叩いていた)。**`/appstate` の照会は前面と答えて黙った**ので、
// 「ツール自身が背面へ送った」という事実だけが確かな材料になる。

import XCTest
@testable import fleetest_mcp
import FTCore

final class MCPBackgroundedByNavigateTests: XCTestCase {

    func testTheNoteNamesTheAppAndBothWaysOut() {
        let note = MCPServer.sentToBackgroundNote("com.apple.mobilesafari", treeIsAppsOwn: false)
        XCTAssertTrue(note.contains("com.apple.mobilesafari"), note)
        XCTAssertTrue(note.contains("whatever is actually on screen now"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), note)
        XCTAssertTrue(note.contains("ft_launch"), note)
    }

    /// **木がアプリ自身のもの**(XCUITest のセッションはアプリに付いたまま)なら「今の画面」と
    /// 言わない —— 実機 iPhone 13 では appSwitcher の直後にアプリの木を返しながらそう言っていた
    func testTheNoteSaysTheTreeIsStillTheAppsOwnWhenTheSessionStaysAttached() {
        let note = MCPServer.sentToBackgroundNote("com.ftester.e2e.ios", treeIsAppsOwn: true)
        XCTAssertTrue(note.contains("still com.ftester.e2e.ios's own tree"), note)
        XCTAssertTrue(note.contains("NOT what is on screen now"), note)
        XCTAssertFalse(note.contains("whatever is actually on screen now"), note)
        XCTAssertTrue(note.contains("ft_launch com.ftester.e2e.ios"), note)
    }

    /// session を名乗らない木でも文章として成立すること(nil で落ちない)
    func testTheNoteToleratesAnUnnamedSession() {
        XCTAssertTrue(MCPServer.sentToBackgroundNote(nil, treeIsAppsOwn: false).contains("ft_launch"))
    }

    /// iOS: 木の sessionBundleID が launch したアプリのままなら「アプリ自身の木」、springboard なら「今の画面」。
    /// 記録は ft_launch でだけ消す(木がアプリのままでも前面とは限らない)
    func testIOSSaysWhoseTreeItIsAndNeverClearsTheRecord() {
        let own = MCPServer.navigatedAwayNote(launched: "com.ftester.e2e.ios", treeSession: "com.ftester.e2e.ios", isAndroid: false)
        XCTAssertTrue(own.note.contains("still com.ftester.e2e.ios's own tree"), own.note)
        XCTAssertFalse(own.appIsBack)
        let board = MCPServer.navigatedAwayNote(launched: "com.ftester.e2e.ios", treeSession: "com.apple.springboard", isAndroid: false)
        XCTAssertTrue(board.note.contains("whatever is actually on screen now"), board.note)
        XCTAssertFalse(board.appIsBack)
    }

    /// Android: 木は常に前面の窓。launch したアプリが前面に戻っていれば黙って記録を消す
    /// (2026-10-15: ランチャーから開いた Maps の木を「画面ではない」と言い、Maps を戻すべきアプリと名指しした)
    func testAndroidTreeIsAlwaysTheForegroundWindow() {
        let back = MCPServer.navigatedAwayNote(launched: "com.ftester.e2e.android", treeSession: "com.ftester.e2e.android", isAndroid: true)
        XCTAssertEqual(back.note, "")
        XCTAssertTrue(back.appIsBack)
        let other = MCPServer.navigatedAwayNote(launched: "com.ftester.e2e.android", treeSession: "com.google.android.apps.maps", isAndroid: true)
        XCTAssertTrue(other.note.contains("whatever is actually on screen now"), other.note)
        XCTAssertFalse(other.note.contains("own tree"), other.note)
        XCTAssertTrue(other.note.contains("com.ftester.e2e.android"), other.note)
        XCTAssertFalse(other.appIsBack)
        // launch の記録が無い(terminate / clearAppData の後)ときに前面のパッケージを名指ししない
        let unknown = MCPServer.navigatedAwayNote(launched: nil, treeSession: "com.google.android.apps.maps", isAndroid: true)
        XCTAssertFalse(unknown.note.contains("com.google.android.apps.maps"), unknown.note)
        XCTAssertFalse(unknown.appIsBack)
    }

    /// 配線: snapshotBody が判定に OS を渡し、戻っていれば記録を消す
    func testSnapshotBodyWiresTheDecision() throws {
        let source = compact(try MCPServerSourceText.combined())
        XCTAssertTrue(source.contains(compact("isAndroid: driver is AndroidDriver)")), "snapshotBody が OS を渡していない")
        XCTAssertTrue(source.contains(compact("if decision.appIsBack { backgroundedByNavigate.remove(Self.sessionKey(args)) }")),
                      "snapshotBody が戻ったときに記録を消していない")
    }

    // MARK: - 配線(ソース走査)

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// **記録するのは home / appSwitcher だけ**。back は画面内で戻るだけのことがあり、
    /// 数えると通常の遷移すべてに注記が付く
    func testNavigateRecordsOnlyTheBackgroundingTargets() throws {
        let source = try MCPServerSourceText.combined()
        XCTAssertTrue(compact(source).contains(compact(
            "if target == \"home\" || target == \"appSwitcher\" {backgroundedByNavigate.insert(")),
                      "ft_navigate が背面化を記録していない")
    }

    /// **ft_launch で消す**。消さないと戻した後もセッションの最後まで注記が出続ける
    func testLaunchClearsTheRecord() throws {
        let source = try MCPServerSourceText.combined()
        XCTAssertTrue(compact(source).contains(compact("backgroundedByNavigate.remove(launchKey)")),
                      "ft_launch が背面化の記録を消していない")
    }

    /// **snapshot の先頭に載る**。載せ忘れると記録だけして誰にも届かない
    func testSnapshotUsesTheRecordWhenTheProbeStaysSilent() throws {
        let source = try MCPServerSourceText.combined()
        XCTAssertTrue(compact(source).contains(compact(
            "if backgroundNote.isEmpty, backgroundedByNavigate.contains(")),
                      "snapshot が背面化の記録を読んでいない")
    }
}
