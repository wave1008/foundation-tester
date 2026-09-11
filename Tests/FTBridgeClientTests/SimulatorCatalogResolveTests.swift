// 名前で指したシミュレータの解決(SimulatorCatalog.resolve)。規則(起動中 → 新しい OS)で決まらない
// 同名の台が複数あるときは、黙って1台目を選ばず UDID を並べて断る(同名が2台ある機で
// `bridge up --device <名前>` が、プロファイルが UDID で指していない方の台を起こした)。

import XCTest
import FTCore
@testable import FTBridgeClient

final class SimulatorCatalogResolveTests: XCTestCase {

    private func sim(_ udid: String, _ name: String, os: String = "iOS 27.0",
                     booted: Bool = false) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: name, os: os, booted: booted)
    }

    private func spec(_ name: String, os: String? = nil) -> DeviceSpec {
        DeviceSpec(name: name, simulator: name, os: os)
    }

    /// **本命**: 同名・同じ OS・どちらも停止中 = 規則で決まらないので断り、両方の UDID を名指しする
    func testTwoIndistinguishableSimulatorsWithTheSameNameAreRefused() {
        let devices = [sim("0113A6C1", "iPhone 17"), sim("6109860E", "iPhone 17")]
        XCTAssertThrowsError(try SimulatorCatalog.resolve(spec: spec("iPhone 17"), in: devices)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("0113A6C1") && text.contains("6109860E"), text)
            XCTAssertTrue(text.contains("UDID"), text)
        }
    }

    /// 起動中の1台があれば規則で決まる = そちらを選ぶ(従来どおり)
    func testTheBootedOneWinsWhenOnlyOneIsBooted() throws {
        let devices = [sim("BOOTED", "iPhone 17", booted: true), sim("SHUT", "iPhone 17")]
        XCTAssertEqual(try SimulatorCatalog.resolve(spec: spec("iPhone 17"), in: devices).udid, "BOOTED")
    }

    /// OS が違えば新しい方を選ぶ(従来どおり)
    func testTheNewerOSWinsWhenTheNamesMatch() throws {
        let devices = [sim("NEW", "iPhone 17", os: "iOS 27.0"), sim("OLD", "iPhone 17", os: "iOS 26.0")]
        XCTAssertEqual(try SimulatorCatalog.resolve(spec: spec("iPhone 17"), in: devices).udid, "NEW")
    }

    /// OS を指定すれば、その OS の中で一意なら選べる
    func testAnOSThatNarrowsToOneResolves() throws {
        let devices = [sim("A", "iPhone 17", os: "iOS 27.0"), sim("B", "iPhone 17", os: "iOS 26.0")]
        XCTAssertEqual(try SimulatorCatalog.resolve(spec: spec("iPhone 17", os: "26.0"), in: devices).udid, "B")
    }

    /// UDID の指定は同名の曖昧さと無関係に通る
    func testAUDIDSpecIsNeverAmbiguous() throws {
        let devices = [sim("0113A6C1", "iPhone 17"), sim("6109860E", "iPhone 17")]
        let byUDID = DeviceSpec(name: "iPhone 17", udid: "6109860E")
        XCTAssertEqual(try SimulatorCatalog.resolve(spec: byUDID, in: devices).udid, "6109860E")
    }
}
