// チェック状態の読み方(CheckStateReading)と checkIsON / checkIsOFF の判定。
// 表の値は iOS 27 のデバイス実測(in-app / XCUITest 同値)と、RN 0.86・Flutter engine・
// Compose Multiplatform の iOS 実装のソースで確かめたもの。

import XCTest
@testable import FTCore

final class CheckStateTests: XCTestCase {

    private func el(_ type: String, value: String? = nil, checked: Bool? = nil, id: String = "cb",
                    ref: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 44, height: 44), depth: 1, checked: checked)
    }

    private func ios(_ e: ElementInfo) -> CheckState { CheckStateReading.state(of: e, isAndroid: false) }
    private func android(_ e: ElementInfo) -> CheckState { CheckStateReading.state(of: e, isAndroid: true) }

    // MARK: - 実測の表

    func testFlutterAndSwiftUIToggleReportTheStateAsSwitchValue() {
        XCTAssertEqual(ios(el("switch", value: "1")), .on)
        XCTAssertEqual(ios(el("switch", value: "0")), .off)
    }

    func testReactNativeReportsTheStateAsValueTokens() {
        XCTAssertEqual(ios(el("other", value: "checkbox, checked")), .on)
        XCTAssertEqual(ios(el("other", value: "checkbox, unchecked")), .off)
        XCTAssertEqual(ios(el("other", value: "radio button, checked")), .on)
        XCTAssertEqual(ios(el("other", value: "radio button, unchecked")), .off)
        XCTAssertEqual(ios(el("other", value: "checkbox, mixed")), .indeterminate)
        // busy や app の accessibilityValue が後ろに付いても読める
        XCTAssertEqual(ios(el("other", value: "checkbox, checked, busy")), .on)
    }

    func testComposeReportsOnlyOnAsSelectedTrait() {
        XCTAssertEqual(ios(el("button", checked: true)), .on)
        XCTAssertEqual(ios(el("button")), .unknown, "Compose iOS の Checkbox のオフは何も出ない")
        // Compose の Switch は value を出さない。スイッチは必ず状態を持つので selected 無し = オフ
        XCTAssertEqual(ios(el("switch", checked: true)), .on)
        XCTAssertEqual(ios(el("switch")), .off)
    }

    func testCustomSwiftUIButtonReportsNothing() {
        XCTAssertEqual(ios(el("button")), .unknown)
    }

    func testWebKitReportsIndeterminateAsTwo() {
        XCTAssertEqual(ios(el("switch", value: "2")), .indeterminate)
        XCTAssertEqual(ios(el("checkBox", value: "2")), .indeterminate, "DOM 経路は checkBox 型で同じ値を載せる")
        XCTAssertEqual(ios(el("checkBox", value: "0", checked: false)), .off)
    }

    func testAndroidCheckableValueIsReadOnAnyNonInputType() {
        XCTAssertEqual(android(el("checkBox", value: "1", checked: true)), .on)
        XCTAssertEqual(android(el("checkBox", value: "0")), .off)
        XCTAssertEqual(android(el("staticText", value: "0")), .off, "CheckedTextView")
        XCTAssertEqual(android(el("button", value: "0")), .off, "checkable な MaterialButton 等")
        // 選択タブ(checkable でない)は value を持たず checked だけ
        XCTAssertEqual(android(el("clickable", checked: true)), .on)
    }

    // MARK: - 誤って読まない

    func testTypedTextIsNeverReadAsState() {
        XCTAssertEqual(android(el("textField", value: "1")), .unknown)
        XCTAssertEqual(ios(el("textField", value: "0")), .unknown)
        XCTAssertEqual(ios(el("textField", value: "unchecked")), .unknown)
        XCTAssertEqual(ios(el("staticText", value: "checked")), .unknown)
    }

    func testNumericValueOutsideStateTypesIsNotReadOnIOS() {
        XCTAssertEqual(ios(el("button", value: "1")), .unknown, "バッジの数字をオンと読まない")
        XCTAssertEqual(ios(el("slider", value: "0")), .unknown)
    }

    func testTokensMustMatchWholeWords() {
        XCTAssertEqual(ios(el("other", value: "unchecked items: 3")), .unknown)
        XCTAssertEqual(ios(el("other", value: "rechecked")), .unknown)
    }

    // MARK: - ブリッジ側(swift test ではリンクされないのでソース走査で守る)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// DOM 経路は el.checked しか読まず、ARIA の checkbox(div role=checkbox)が常にオフになっていた
    func testDOMWalkReadsAriaAndMixedState() throws {
        let dom = try source("Sources/FTCore/WebViewDOMSnapshot.swift")
        XCTAssertTrue(dom.contains("el.getAttribute(\"aria-checked\")"))
        XCTAssertTrue(dom.contains("el.indeterminate === true"))
        XCTAssertTrue(dom.contains("node.value = mixed ? \"2\" : (on ? \"1\" : \"0\");"))
        XCTAssertEqual(WebViewDOM.typeName(role: "switch"), "Switch")
    }

    // MARK: - セレクタと表示

    func testSelectorCheckedFilterUsesTheDerivedState() {
        let elements = [el("switch", value: "1", id: "a", ref: 1), el("switch", value: "0", id: "b", ref: 2),
                        el("switch", value: "2", id: "c", ref: 3), el("button", id: "d", ref: 4)]
        XCTAssertEqual(StepExecutor.candidates(FlowLocator(checked: true), elements: elements)?.map(\.ref), [1])
        XCTAssertEqual(StepExecutor.candidates(FlowLocator(checked: false), elements: elements)?.map(\.ref), [2, 4],
                       "checked=false はオフと状態を持たない要素(indeterminate は含めない)")
    }

    func testRenderingMarksDerivedOnAndIndeterminate() {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [el("switch", value: "1", id: "a", ref: 1),
                                                   el("switch", value: "2", id: "b", ref: 2),
                                                   el("switch", value: "0", id: "c", ref: 3)],
                                        truncatedCount: 0)
        let lines = SnapshotRenderer.render(snapshot).split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.contains("id=a") && $0.contains(" checked") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("id=b") && $0.contains(" indeterminate") })
        XCTAssertFalse(lines.contains { $0.contains("id=c") && ($0.contains(" checked") || $0.contains(" indeterminate")) })
    }
}
