// (machine, name) を一意キーにするデバイス分類の規則を固定する。
// 「別の機械の同名を許す」ことと「同じ機械の同名は重複」が対で、片方だけ壊れると
// 別の機械のデバイスを黙って操作する形になるため、両方向を等号で押さえる。

import XCTest
@testable import FTCore

final class DeviceMachineGroupingTests: XCTestCase {
    private func entry(_ platform: String, _ name: String, machine: String? = nil,
                       udid: String? = nil, enabled: Bool? = nil) -> RunDeviceEntry {
        RunDeviceEntry(platform: platform, spec: DeviceSpec(name: name, machine: machine, udid: udid),
                       enabled: enabled)
    }

    /// 空文字・"local"(前後の空白込み)は手元(nil)に畳む。リモートは名前のまま
    func testMachineIsNormalizedPerDevice() {
        let entries = DeviceMachineGrouping.entries(runDevices: [
            entry("ios", "a"), entry("ios", "b", machine: "M2Ultra"),
            entry("ios", "c", machine: " local "), entry("ios", "d", machine: ""),
        ], enabledOnly: false)
        XCTAssertEqual(entries.map(\.machine), [nil, "M2Ultra", nil, nil])
    }

    func testEnabledOnlyDropsDisabledEntriesAndKeepsOrder() {
        let devices = [entry("ios", "a"), entry("android", "b", enabled: false),
                       entry("android", "c", enabled: true), entry("ios", "d")]
        XCTAssertEqual(DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: true).map(\.name),
                       ["a", "c", "d"])
        XCTAssertEqual(DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: false).map(\.name),
                       ["a", "b", "c", "d"])
        XCTAssertEqual(DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: false).map(\.platform),
                       ["ios", "android", "android", "ios"])
    }

    func testRosterEntriesAreIOSThenAndroid() {
        let roster = DeviceRoster(entries: DeviceMachineGrouping.entries(runDevices: [
            entry("android", "e1"), entry("ios", "s1", machine: "local"), entry("ios", "s2", machine: "M1"),
        ], enabledOnly: false))
        let entries = DeviceMachineGrouping.entries(roster: roster)
        XCTAssertEqual(entries.map(\.name), ["s1", "s2", "e1"])
        XCTAssertEqual(entries.map(\.machine), [nil, "M1", nil])
    }

    func testSameNameOnDifferentMachinesIsNotADuplicate() {
        let entries = DeviceMachineGrouping.entries(runDevices: [
            entry("ios", "iPhone-01"), entry("ios", "iPhone-01", machine: "M1Ultra"),
        ], enabledOnly: false)
        XCTAssertNil(DeviceMachineGrouping.firstDuplicate(in: entries))
    }

    /// platform を跨いでも同じ機械の同名は重複。無効の台も数える
    func testSameNameOnTheSameMachineIsADuplicateAcrossPlatforms() {
        let entries = DeviceMachineGrouping.entries(runDevices: [
            entry("ios", "iPhone-01", machine: "M1Ultra"),
            entry("android", "iPhone-01", machine: "M1Ultra", enabled: false),
        ], enabledOnly: false)
        XCTAssertEqual(DeviceMachineGrouping.firstDuplicate(in: entries)?.name, "iPhone-01")
    }

    // MARK: - workerID(ApiMonitorCommand.MonitorTarget.id / ApiRunMachineFanout が共有する規則)

    func testWorkerIDOmitsTheHostWhenLocal() {
        XCTAssertEqual(DeviceMachineGrouping.workerID(platform: "ios", machine: nil, name: "iPhone A"),
                       "ios:iPhone A")
        XCTAssertEqual(DeviceMachineGrouping.workerID(platform: "ios", machine: "local", name: "iPhone A"),
                       "ios:iPhone A", "\"local\" は normalize で nil に畳まれるので手元と同じ形")
    }

    func testWorkerIDIncludesTheHostWhenRemote() {
        XCTAssertEqual(DeviceMachineGrouping.workerID(platform: "android", machine: "M1Max", name: "Pixel 10"),
                       "android:M1Max/Pixel 10")
    }

    func testGroupsKeepFirstAppearanceOrderAndSeparateLocalFromRemote() {
        let entries = DeviceMachineGrouping.entries(runDevices: [
            entry("ios", "r1", machine: "M1Ultra"), entry("ios", "l1"),
            entry("ios", "r2", machine: "M1Ultra"), entry("ios", "l2"),
        ], enabledOnly: true)
        let groups = DeviceMachineGrouping.groups(entries) { $0.machine }
        XCTAssertEqual(groups.map(\.machine), ["M1Ultra", nil])
        XCTAssertEqual(groups.map { $0.devices.map(\.name) }, [["r1", "r2"], ["l1", "l2"]])
    }
}
