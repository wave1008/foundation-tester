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
        let note = MCPServer.sentToBackgroundNote("com.apple.mobilesafari")
        XCTAssertTrue(note.contains("com.apple.mobilesafari"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), note)
        XCTAssertTrue(note.contains("ft_launch"), note)
    }

    /// session を名乗らない木でも文章として成立すること(nil で落ちない)
    func testTheNoteToleratesAnUnnamedSession() {
        XCTAssertTrue(MCPServer.sentToBackgroundNote(nil).contains("ft_launch"))
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
