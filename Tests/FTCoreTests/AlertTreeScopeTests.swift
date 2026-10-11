// アラートが前面にある間の木の範囲(AlertTreeScope)。MCP の snapshotBody と DSL の失敗レポートが共有する

import XCTest
@testable import FTCore

final class AlertTreeScopeTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ label: String, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 40, y: Double(ref * 50), width: 300, height: 44), depth: depth)
    }

    /// いちばん手前(木の順で最後)の alert を採り、その部分木だけを残す。背面の行も、alert の後ろの兄弟も残さない
    func testOnlyTheFrontAlertSubtreeIsKept() throws {
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [el(1, "button", "背面", depth: 1),
                       el(2, "alert", "奥のアラート", depth: 1), el(3, "button", "奥のOK", depth: 2),
                       el(4, "alert", "手前のアラート", depth: 1), el(5, "button", "OK", depth: 2),
                       el(6, "button", "キャンセル", depth: 2), el(7, "button", "後ろの兄弟", depth: 1)],
            truncatedCount: 0)
        let alert = try XCTUnwrap(AlertTreeScope.frontInAppAlert(in: snapshot))
        XCTAssertEqual(alert.ref, 4)
        XCTAssertEqual(AlertTreeScope.alertOnly(alert, in: snapshot).elements.map(\.ref), [4, 5, 6])
        XCTAssertEqual(AlertTreeScope.buttonLabels(of: alert, in: snapshot), ["OK", "キャンセル"])
        XCTAssertNil(AlertTreeScope.frontInAppAlert(in: SnapshotResponse(
            sessionBundleID: nil, screen: snapshot.screen, elements: [el(1, "button", "背面", depth: 1)],
            truncatedCount: 0)))
    }

    /// **描かれていない alert(枠が0・画面の外)では木を伏せない**(閉じた後の残りで伏せると、押しても何も起きない
    /// アラートだけの画面が見え続ける)
    func testAnAlertThatIsNotOnScreenIsIgnored() {
        var offscreen = el(2, "alert", "閉じた後の残り", depth: 1)
        offscreen.frame = FTRect(x: 40, y: 900, width: 300, height: 200)
        var zero = el(3, "alert", "枠が0", depth: 1)
        zero.frame = FTRect(x: 40, y: 100, width: 0, height: 0)
        let snapshot = SnapshotResponse(sessionBundleID: "com.example.app",
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [el(1, "button", "背面", depth: 1), offscreen, zero],
                                        truncatedCount: 0)
        XCTAssertNil(AlertTreeScope.frontInAppAlert(in: snapshot))
    }
}
