// ft_clear_input が throw すると recordInteraction を通らない欠陥(M5b・2026-09-17 実測)。
// ref 指定の clearInput はランナーが既にタップを撃った後に失敗しうる(焦点待ちの 422 等)ので、
// 記録せずに投げると次の ft_type/ft_snapshot が「このセッションの誰も変えていないのに
// 木が変わった」と外部要因(他プロセス・人)のせいにする(RefScreenProvenanceTests の
// screenChangedUnderRefNote 参照)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class ClearInputFailureRecordingTests: XCTestCase {

    private func element(_ ref: Int, id: String, label: String,
                         y: Double = 78, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 76, height: 48), depth: 3)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.ftester.e2e",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    /// ref 350 は clearInput の対象(入力欄型でないと ft_clear_input が driver へ届く前に断るため
    /// textField にする)。ref 350 自身は変えず、シェルの外側だけ入れ替えて「木が別物になった」を作る
    private var before: SnapshotResponse {
        tree([element(350, id: "field_single", label: "single", type: "textField"),
              element(352, id: "txt_screen_title", label: "セレクタ", y: 90, type: "staticText")])
    }
    private var after: SnapshotResponse {
        tree([element(350, id: "field_single", label: "single", type: "textField"),
              element(301, id: "txt_screen_title", label: "ライフサイクル", y: 90, type: "staticText")])
    }

    /// **本命**: clearInput が失敗しても、後続の ft_type は「誰も変えていない」と外部要因を
    /// 名指ししない(この session 自身の直前の操作で説明がつく)
    func testFailedClearInputIsStillRecordedSoTheNextCallDoesNotBlameExternalActors() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = before
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        driver.failing = ["clearInput"]
        do {
            _ = try await server.call(tool: "ft_clear_input", args: ["ref": 350])
            XCTFail("clearDriver.clearInput の失敗はそのまま呼び手へ再送出されるはず")
        } catch {
            // 期待どおり失敗(FakeDriver.Boom がそのまま、または connectionLostHint 付きの MCPError)
        }

        driver.failing = []
        driver.scriptedSnapshots = [after, after]
        let result = try await server.call(tool: "ft_type", args: ["ref": 350, "text": "x"])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("this session's own actions"), text)
        XCTAssertFalse(text.contains("nothing this session did"), text)
    }

    /// **配線の精度**: 失敗した clearInput は sessionActionCounts をちょうど1回だけ進める
    /// (0回=記録漏れの再発・2回=二重記録のどちらも壊れた形)
    func testFailedClearInputAdvancesTheActionCountExactlyOnce() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = before
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let key = MCPServer.engineKey([:])
        XCTAssertEqual(server.sessionActionCounts[key] ?? 0, 0)

        driver.failing = ["clearInput"]
        _ = try? await server.call(tool: "ft_clear_input", args: ["ref": 350])
        XCTAssertEqual(server.sessionActionCounts[key], 1)
    }

    /// **陰性対照**: ref を渡さない clearInput(タップを撃たない経路)が失敗しても記録しない
    /// (ref なしは画面を変えていないので、記録すると逆に「変えていないのに変えた」ことになる)
    func testFailedClearInputWithoutRefDoesNotRecord() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = before
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let key = MCPServer.engineKey([:])

        driver.failing = ["clearInput"]
        _ = try? await server.call(tool: "ft_clear_input", args: [:])
        XCTAssertEqual(server.sessionActionCounts[key] ?? 0, 0)
    }
}
