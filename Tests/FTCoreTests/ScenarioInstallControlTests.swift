// installApp() の子側 RPC 待機機構(ScenarioInstall.swift)を実プロセス無しで固定する
import XCTest
@testable import FTCore

final class ScenarioInstallControlTests: XCTestCase {

    // MARK: - parse(line:)

    func testParseValidInstallResultLine() {
        let parsed = ScenarioInstallControl.parse(
            line: #"{"cmd":"installResult","id":7,"ok":true,"message":"note"}"#)
        XCTAssertEqual(parsed?.id, 7)
        XCTAssertEqual(parsed?.ok, true)
        XCTAssertEqual(parsed?.message, "note")
    }

    func testParseIgnoresNonInstallResultCommands() {
        XCTAssertNil(ScenarioInstallControl.parse(line: #"{"cmd":"continue"}"#))
        XCTAssertNil(ScenarioInstallControl.parse(line: "not json"))
        XCTAssertNil(ScenarioInstallControl.parse(line: ""))
        XCTAssertNil(ScenarioInstallControl.parse(line: #"{"cmd":"installResult"}"#), "id 欠落")
    }

    func testParseDefaultsOkAndMessageWhenMissing() {
        let parsed = ScenarioInstallControl.parse(line: #"{"cmd":"installResult","id":3}"#)
        XCTAssertEqual(parsed?.id, 3)
        XCTAssertEqual(parsed?.ok, false)
        XCTAssertEqual(parsed?.message, "")
    }

    // MARK: - request/resolve

    func testRequestResolvesWithParentResponse() async {
        let control = ScenarioInstallControl()
        let result = await control.request(timeoutSeconds: 5) { id in
            Task { await control.resolve(id: id, ok: true, message: "note") }
        }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "note")
    }

    func testRequestSurfacesFailureFromParent() async {
        let control = ScenarioInstallControl()
        let result = await control.request(timeoutSeconds: 5) { id in
            Task { await control.resolve(id: id, ok: false, message: "package not found") }
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "package not found")
    }

    func testRequestTimesOutWithoutAResponse() async {
        let control = ScenarioInstallControl()
        let result = await control.request(timeoutSeconds: 0.05) { _ in }
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("no response"), result.message)
    }

    func testRequestIDsIncrementAcrossCalls() async {
        let control = ScenarioInstallControl()
        var seenIDs: [Int] = []
        _ = await control.request(timeoutSeconds: 5) { id in
            seenIDs.append(id)
            Task { await control.resolve(id: id, ok: true, message: "") }
        }
        _ = await control.request(timeoutSeconds: 5) { id in
            seenIDs.append(id)
            Task { await control.resolve(id: id, ok: true, message: "") }
        }
        XCTAssertEqual(seenIDs, [1, 2])
    }

    /// 未知の id への resolve は無視される(タイムアウト後に遅れて届いた応答等)
    func testResolveForUnknownIDIsIgnored() async {
        let control = ScenarioInstallControl()
        await control.resolve(id: 999, ok: true, message: "late")
        let result = await control.request(timeoutSeconds: 0.05) { _ in }
        XCTAssertFalse(result.ok, "無関係な resolve が別のリクエストを解決してはいけない")
    }
}
