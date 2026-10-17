// devices[].foldable は true/false を書き、nil(未確定)は欄ごと省く(拡張は欠落を「まだ分からない」= ボタンを出さない側に読む)。
// リモートの子の JSON を親が読み直して中継する(RemoteMonitorFanout)ので、往復で値が保たれること。

import XCTest

@testable import fleetest

final class ApiMonitorDeviceInfoEncodingTests: XCTestCase {
    private func make(foldable: Bool?) -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(
            id: "ios:A", name: "A", platform: "ios", state: "connected", detail: "", udid: nil, serial: nil,
            health: nil, renderMode: nil, inRun: false, inSession: false, kind: "virtual", host: nil, port: nil,
            recording: false, registered: true, machine: nil, frozen: false, wired: nil,
            streamedByOther: nil, bridgeRunning: nil, storage: nil,
            storageMeasuring: false, storageRefreshId: nil, foldable: foldable)
    }

    private func json(_ info: ApiMonitorDeviceInfo) throws -> [String: Any] {
        let data = try JSONEncoder().encode(info)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBooleanFoldableIsWritten() throws {
        XCTAssertEqual(try json(make(foldable: true))["foldable"] as? Bool, true)
        XCTAssertEqual(try json(make(foldable: false))["foldable"] as? Bool, false)
    }

    /// inSession は拡張が必須欄として読む(monitorDeviceModel.ts の isMonitorDevice)ので、false でも欄ごと書く
    func testInSessionIsAlwaysWritten() throws {
        XCTAssertEqual(try json(make(foldable: nil))["inSession"] as? Bool, false)
    }

    func testUnknownFoldableIsOmitted() throws {
        XCTAssertFalse(try json(make(foldable: nil)).keys.contains("foldable"))
    }

    func testRoundTripKeepsFoldable() throws {
        for value in [true, false, nil] as [Bool?] {
            let data = try JSONEncoder().encode(make(foldable: value))
            let decoded = try JSONDecoder().decode(ApiMonitorDeviceInfo.self, from: data)
            XCTAssertEqual(decoded.foldable, value)
        }
    }
}
