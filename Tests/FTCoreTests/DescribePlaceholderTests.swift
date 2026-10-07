// 要素の名指し(注記の中の「どの欄か」)。id もラベルも無い入力欄を型名だけで言うと、同じ画面の別の入力欄
// (焦点が残っている欄など)と区別できず、焦点救済の注記が別の欄を指しているように読めた(Pixel 3a の MCP)

import XCTest
@testable import FTCore

final class DescribePlaceholderTests: XCTestCase {

    private func field(id: String?, label: String?, placeholder: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: id, label: label, value: nil,
                    placeholder: placeholder, enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
    }

    func testPlaceholderNamesAFieldWithoutIdOrLabel() {
        XCTAssertEqual(TapTargetGeometry.describe(field(id: nil, label: nil, placeholder: "容器つき")),
                       "textField ph=\"容器つき\"")
    }

    func testIdAndLabelStillWinOverThePlaceholder() {
        XCTAssertEqual(TapTargetGeometry.describe(field(id: "field_single", label: nil, placeholder: "単一行")), "#field_single")
        XCTAssertEqual(TapTargetGeometry.describe(field(id: nil, label: "名前", placeholder: "単一行")), "textField \"名前\"")
        XCTAssertEqual(TapTargetGeometry.describe(field(id: nil, label: nil, placeholder: nil)), "textField")
    }
}
