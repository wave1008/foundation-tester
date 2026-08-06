import XCTest
@testable import FTCore

/// set-of-mark 1行の形。**読み手はエージェント**なので、印の有無がそのまま
/// 「どう書くか」の判断材料になる(scroll = `scrollFrame:` に指定できる容器)。
final class SnapshotRenderingTests: XCTestCase {

    private func element(_ ref: Int, id: String?, scrollable: Bool?) -> ElementInfo {
        ElementInfo(ref: ref, type: "scrollView", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 400, height: 500), depth: 1,
                    scrollable: scrollable)
    }

    func testScrollableContainerIsMarked() {
        let line = SnapshotRenderer.renderElement(element(1, id: "list_rows", scrollable: true))
        XCTAssertEqual(line, "[1] scrollView id=list_rows scroll (0,100 400x500)")
    }

    /// 申告できないエンジンでは nil。**印が無い = スクロールしない、ではない**ので、
    /// 何も足さない(推測の印を出すと読み手はそれを事実として使う)
    func testUndeclaredContainerGetsNoMark() {
        let line = SnapshotRenderer.renderElement(element(2, id: "list_rows", scrollable: nil))
        XCTAssertEqual(line, "[2] scrollView id=list_rows (0,100 400x500)")
    }
}
