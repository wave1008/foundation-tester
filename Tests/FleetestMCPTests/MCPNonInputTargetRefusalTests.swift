// `ft_type` / `ft_clear_input` の ref が入力欄でなく(`TypeReadback.isTextInput`)、かつ内側に
// ちょうど1つの入力欄を持つ容器でもない(`TapTargetGeometry.nonInputTypeTargetNote` が nil =
// 0個か2個以上)なら**撃つ前に拒否する**。撃つと、送信ボタンの ref なら押された**後**で読み返しが
// 失敗し(空のまま送信される)、in-app エンジンなら焦点のある別の欄へ入って成功扱いになる。
// 容器(内側に入力欄が1つ)は警告のうえで撃つ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPNonInputTargetRefusalTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                // ref 1: ボタン。内側に入力欄なし → 拒否されるべき
                ElementInfo(ref: 1, type: "button", identifier: "btn_submit", label: "Submit",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1),
                // ref 2: 容器。内側に入力欄が2つ(どちらを指すか言えない)→ 拒否されるべき
                ElementInfo(ref: 2, type: "other", identifier: "wrap_two", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 50, width: 200, height: 80), depth: 1),
                ElementInfo(ref: 3, type: "textField", identifier: nil, label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 50, width: 200, height: 40), depth: 2),
                ElementInfo(ref: 4, type: "textField", identifier: nil, label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 90, width: 200, height: 40), depth: 2),
                // ref 5: 容器。内側に入力欄がちょうど1つ → 警告のうえで撃つ(従来どおり)
                ElementInfo(ref: 5, type: "other", identifier: "wrap_one", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 140, width: 200, height: 40), depth: 1),
                ElementInfo(ref: 6, type: "textField", identifier: "inner_field", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 140, width: 200, height: 40), depth: 2),
                // ref 7: 本物の入力欄 → 通常どおり
                ElementInfo(ref: 7, type: "textField", identifier: "search_box", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 190, width: 200, height: 40), depth: 1),
            ],
            truncatedCount: 0)
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: - ft_type

    func testTypeIntoAButtonWithNoInnerFieldIsRefusedBeforeFiring() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "hello"])
            XCTFail("入力欄でも容器でもない ref への type は拒否されるべき")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("not a text field"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("type(ref:1") },
                       "拒否したはずのボタンへ実際に type してしまった: \(driver.calls)")
    }

    func testTypeIntoAContainerWithTwoInnerFieldsIsRefused() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_type", args: ["ref": 2, "text": "hello"])
            XCTFail("入力欄を2つ持つ容器はどちらを指すか言えないので拒否されるべき")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("not a text field"),
                          error.localizedDescription)
        }
    }

    /// **陰性対照**: 内側に入力欄がちょうど1つの容器は、従来どおり警告のうえで撃つ(拒否しない)
    func testTypeIntoAContainerWithExactlyOneInnerFieldStillFiresWithAWarning() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_type", args: ["ref": 5, "text": "hello"])
        let text = body(result)
        XCTAssertTrue(text.contains("warning:"), text)
        XCTAssertTrue(text.contains("not a text field"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("type(ref:") }, "\(driver.calls)")
    }

    /// **陰性対照**: 本物の入力欄は警告も拒否も無く通常どおり
    func testTypeIntoARealTextFieldIsUnaffected() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_type", args: ["ref": 7, "text": "hello"])
        let text = body(result)
        XCTAssertFalse(text.contains("not a text field"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("type(ref:") }, "\(driver.calls)")
    }

    // MARK: - ft_clear_input(同じ門)

    func testClearInputOnAButtonWithNoInnerFieldIsRefused() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_clear_input", args: ["ref": 1])
            XCTFail("入力欄でも容器でもない ref への clear は拒否されるべき")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("not a text field"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("clearInput(") }, "\(driver.calls)")
    }

    func testClearInputOnARealTextFieldIsUnaffected() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_clear_input", args: ["ref": 7])
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("clearInput(") }, "\(driver.calls)")
    }
}
