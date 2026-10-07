// ref の振り直し(世代管理)は要素を複写して ref だけ差し替える。欄を並べて作り直すと、後から足した欄
// (inOverlayWindow 等)を落とし、手前の窓の中身が「手前の窓に覆われている」と誤って警告された

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPRefRemapKeepsFieldsTests: XCTestCase {

    func testRemappingKeepsEveryFieldButTheRef() {
        let original = ElementInfo(ref: 3, type: "button", identifier: "btn_banner_close", label: "閉じる", value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 133, y: 104, width: 135, height: 61),
                                   depth: 4, checked: true, web: nil, focused: nil, scrollable: true, z: 2, range: "0-1",
                                   axClass: "UIButton", scrollActions: ["up"], inOverlayWindow: true)
        let remapped = MCPServer.withRef(original, 103)
        XCTAssertEqual(remapped.ref, 103)
        var expected = original
        expected.ref = 103
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(remapped), try encoder.encode(expected))
        XCTAssertEqual(remapped.inOverlayWindow, true)
    }
}
