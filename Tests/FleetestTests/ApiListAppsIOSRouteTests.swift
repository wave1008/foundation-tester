// `fleetest api list-apps` の iOS 経路選択(欠陥①: 実機は /status.device に機種名しか返さず、
// bootedSimulatorUDID にそのまま渡すと必ず throw する)。ApiListApps.route は
// port → `.fleetest/bridge-<port>.device` の記録 → 実機か simctl かの判定だけを切り出した
// 純粋関数なので、デバイス・ファイルシステムに触らず固定できる。
import XCTest

@testable import fleetest

final class ApiListAppsIOSRouteTests: XCTestCase {

    func testRoutesToPhysicalWhenRecordExists() {
        XCTAssertEqual(ApiListApps.route(recordedUDID: "00008130-001819863E60001C"),
                       .physical(udid: "00008130-001819863E60001C"))
    }

    func testRoutesToSimulatorWhenNoRecord() {
        XCTAssertEqual(ApiListApps.route(recordedUDID: nil), .simulator)
    }
}
