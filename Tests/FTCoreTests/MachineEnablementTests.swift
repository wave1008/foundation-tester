// 「マシン有効」の保存形(false だけを保存・nil は既存を保つ)と、振り分けで外す機械の決め方。
// 振り分け側(DeviceMachineRunner.plan / FleetRunner)は RunProfileMachineDispatchTests。

import XCTest
@testable import FTCore
import FTRemote

final class MachineEnablementTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteHostEntry {
        try JSONDecoder().decode(RemoteHostEntry.self, from: Data(json.utf8))
    }

    func testMissingKeyIsEnabled() throws {
        let entry = try decode(#"{"machine":"M1Max","host":"user@h"}"#)
        XCTAssertNil(entry.enabled)
        XCTAssertTrue(entry.isEnabled)
    }

    func testFalseRoundTrips() throws {
        let entry = RemoteHostEntry(machine: "M1Max", host: "user@h", enabled: false)
        let back = try decode(String(data: JSONEncoder().encode(entry), encoding: .utf8)!)
        XCTAssertEqual(back.enabled, false)
        XCTAssertFalse(back.isEnabled)
    }

    /// upsert は nil を「既存を保つ」と読み、true は nil へ畳む(保存するのは false だけ)
    func testUpsertKeepsExistingAndFoldsTrueToNil() {
        let existing = [RemoteHostEntry(machine: "M1Max", host: "user@h", color: "mint", enabled: false)]
        let kept = RemoteHostRegistry.upsert(RemoteHostEntry(machine: "M1Max", host: "user@h2"), into: existing)
        XCTAssertEqual(kept.first?.enabled, false)
        let turnedOn = RemoteHostRegistry.upsert(
            RemoteHostEntry(machine: "M1Max", host: "user@h", enabled: true), into: existing)
        XCTAssertNil(turnedOn.first?.enabled)
        XCTAssertTrue(turnedOn.first?.isEnabled ?? false)
        let fresh = RemoteHostRegistry.upsert(RemoteHostEntry(machine: "New", host: "u@n"), into: [])
        XCTAssertNil(fresh.first?.enabled)
    }

    func testDisabledMachinesIncludesLocalOnlyWhenTurnedOff() {
        let hosts = [RemoteHostEntry(machine: "A", host: "u@a", enabled: false),
                     RemoteHostEntry(machine: "B", host: "u@b")]
        XCTAssertEqual(MachineEnablement.disabledMachines(config: LocalConfig(remoteHosts: hosts)), ["A"])
        XCTAssertEqual(MachineEnablement.disabledMachines(
            config: LocalConfig(remoteHosts: hosts, localMachineEnabled: false)), ["A", "local"])
        XCTAssertEqual(MachineEnablement.disabledMachines(config: LocalConfig()), [])
    }

    func testPartitionKeepsOrderAndNamesEachExcludedMachineOnce() {
        let devices = [RunDeviceMachine(machine: nil, name: "l", platform: "ios"),
                       RunDeviceMachine(machine: "A", name: "a1", platform: "ios"),
                       RunDeviceMachine(machine: "B", name: "b", platform: "android"),
                       RunDeviceMachine(machine: "A", name: "a2", platform: "android")]
        let (kept, excluded) = MachineEnablement.partition(devices, disabled: ["A", "local"])
        XCTAssertEqual(kept.map(\.name), ["b"])
        XCTAssertEqual(excluded, ["local", "A"])
    }
}
