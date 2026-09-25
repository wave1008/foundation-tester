// `ft_tap(容器)` → ref なし `ft_type` の救済(§19 F13 の MCP 版)。
// Android は容器を叩いても前の欄の焦点を外さないので、ref なし type は前の欄へ入って
// 「Typed」とだけ返していた(Pixel 3a)。DSL の `retypeTargetIfUnfocused` と同じ規律で、
// 判定は `InputFocusRescue`(FTCore)を共有する: ①焦点が叩いた要素の外にあり、内側の入力欄が
// ちょうど1つ → そこへ撃つ ②一意でなければ従来どおり撃つが警告 ③焦点が叩いた欄(の内側)なら
// 何もしない ④直前が tap でなければ木を1枚も払わない

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTypeFocusRescueTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    private func el(_ ref: Int, _ type: String, id: String?, frame: FTRect,
                    focused: Bool? = nil, value: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil,
                    enabled: true, frame: frame, depth: 1, focused: focused)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    /// [1] 前の欄(焦点あり)/ [2] 容器 #field_wrapped / [3] その中身(id 無し)
    private func screen(focusOn: Int, innerFields: Int = 1, innerValue: String? = nil) -> SnapshotResponse {
        var elements = [
            el(1, "textField", id: "field_single", frame: FTRect(x: 16, y: 100, width: 300, height: 40),
               focused: focusOn == 1, value: "kb"),
            el(2, "other", id: "field_wrapped", frame: FTRect(x: 16, y: 200, width: 300, height: 80)),
            el(3, "textField", id: nil, frame: FTRect(x: 24, y: 220, width: 280, height: 40),
               focused: focusOn == 3, value: innerValue),
        ]
        if innerFields == 2 {
            elements.append(el(4, "textField", id: nil, frame: FTRect(x: 24, y: 262, width: 280, height: 16)))
        }
        return snapshot(elements)
    }

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func typeCalls() -> [String] { driver.calls.filter { $0.hasPrefix("type(") } }

    private func text(_ result: [[String: Any]]) -> String {
        result.compactMap { $0["text"] as? String }.joined()
    }

    /// ①焦点が前の欄に残ったまま容器を叩いた → 中身の入力欄へ撃ち、そう言う
    func testFocusLeftOnAnotherFieldRetargetsToTheSingleInnerField() async throws {
        driver.snapshotResponse = screen(focusOn: 1)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        // 救済の1枚(焦点はまだ [1])→ 入力後の読み返し([3] に W3)
        driver.scriptedSnapshots = [screen(focusOn: 1), screen(focusOn: 3, innerValue: "W3")]

        let result = try await server.call(tool: "ft_type", args: ["text": "W3"])

        XCTAssertEqual(typeCalls(), ["type(ref:3,text:W3)"], "\(driver.calls)")
        let body = text(result)
        XCTAssertTrue(body.contains("tapping #field_wrapped left input focus on #field_single"), body)
        XCTAssertTrue(body.contains("sent to the input field inside it"), body)
    }

    /// ③焦点が叩いた容器の中身に立っている → 従来どおり焦点任せ(ref なし)で撃ち、救済の文言は出ない
    func testFocusInsideTheTappedElementTypesAsBefore() async throws {
        driver.snapshotResponse = screen(focusOn: 1)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        driver.scriptedSnapshots = [screen(focusOn: 3), screen(focusOn: 3, innerValue: "W3")]

        let result = try await server.call(tool: "ft_type", args: ["text": "W3"])

        XCTAssertEqual(typeCalls(), ["type(ref:nil,text:W3)"], "\(driver.calls)")
        XCTAssertFalse(text(result).contains("left input focus"), text(result))
    }

    /// ②焦点は外にあるが中身の入力欄が2つ → 撃つが警告(推測して選ばない)
    func testAmbiguousInnerFieldsTypeWithAWarningInstead() async throws {
        driver.snapshotResponse = screen(focusOn: 1, innerFields: 2)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        driver.scriptedSnapshots = [screen(focusOn: 1, innerFields: 2), screen(focusOn: 1, innerFields: 2)]

        let result = try await server.call(tool: "ft_type", args: ["text": "W3"])

        XCTAssertEqual(typeCalls(), ["type(ref:nil,text:W3)"], "\(driver.calls)")
        let body = text(result)
        XCTAssertTrue(body.contains("warning: tapping #field_wrapped left input focus on #field_single"), body)
        XCTAssertTrue(body.contains("no single input field inside the tapped element"), body)
    }

    /// ④直前が tap でない(swipe を挟んだ)→ 救済の木を払わず、従来どおり撃つ
    func testNoPrecedingTapPaysNoRescueRead() async throws {
        driver.snapshotResponse = screen(focusOn: 1)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        _ = try await server.call(tool: "ft_swipe", args: ["finger": "up"])
        let before = driver.calls.count
        driver.scriptedSnapshots = [screen(focusOn: 1)]

        _ = try await server.call(tool: "ft_type", args: ["text": "W3"])

        XCTAssertEqual(typeCalls(), ["type(ref:nil,text:W3)"], "\(driver.calls)")
        // 入力の前に木を読んでいない(最初の呼び出しが type)
        XCTAssertTrue(driver.calls[before].hasPrefix("type("), "\(driver.calls[before...])")
    }
}
