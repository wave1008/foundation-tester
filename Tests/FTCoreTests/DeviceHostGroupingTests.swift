// (host, name) を一意キーにするデバイス解決の規則を固定する。
// 「別ホストの同名を許す」ことと「host を書いていない曖昧な参照は止める」ことが対で、
// 片方だけ壊れると別の機械のデバイスを黙って操作する形になるため、両方向を等号で押さえる。

import XCTest
@testable import FTCore

final class DeviceHostGroupingTests: XCTestCase {
    private func machine(host: String? = nil,
                         ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineProfile {
        MachineProfile(machine: host,
                       ios: ios.isEmpty ? nil : MachineDeviceList(devices: ios),
                       android: android.isEmpty ? nil : MachineDeviceList(devices: android))
    }

    func testDeviceHostFallsBackToTheMachineProfileHost() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            host: "M1Ultra",
            ios: [DeviceSpec(name: "a"), DeviceSpec(name: "b", machine: "M2Ultra"),
                  DeviceSpec(name: "c", machine: "local")]))
        XCTAssertEqual(entries.map(\.host), ["M1Ultra", "M2Ultra", nil])
    }

    /// 空文字は「未指定」= マシン既定へ落ちる / "local" は「手元」の明示でマシン既定より強い。
    /// 同一視すると、リモート既定のプロファイルに手元のデバイスを1台混ぜられなくなる
    func testEmptyMeansUnsetButLocalOverridesTheMachineDefault() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            host: "M1Ultra",
            ios: [DeviceSpec(name: "a", machine: ""), DeviceSpec(name: "b", machine: " local ")]))
        XCTAssertEqual(entries.map(\.host), ["M1Ultra", nil])
    }

    func testSameNameOnDifferentHostsIsNotADuplicate() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            ios: [DeviceSpec(name: "iPhone-01"), DeviceSpec(name: "iPhone-01", machine: "M1Ultra")]))
        XCTAssertNil(DeviceHostGrouping.firstDuplicate(in: entries))
    }

    func testSameNameOnTheSameHostIsADuplicate() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            host: "M1Ultra",
            ios: [DeviceSpec(name: "iPhone-01")],
            android: [DeviceSpec(name: "iPhone-01", machine: "M1Ultra")]))
        XCTAssertEqual(DeviceHostGrouping.firstDuplicate(in: entries)?.name, "iPhone-01")
    }

    func testUnqualifiedRefResolvesWhenTheNameIsUnique() {
        let entries = DeviceHostGrouping.entries(machine: machine(ios: [DeviceSpec(name: "a")]))
        guard case .found(let entry) = DeviceHostGrouping.resolve(RunDeviceRef(name: "a"),
                                                                 in: entries) else {
            return XCTFail("expected .found")
        }
        XCTAssertNil(entry.host)
    }

    func testUnqualifiedRefIsAmbiguousWhenTheNameExistsOnTwoHosts() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            ios: [DeviceSpec(name: "a"), DeviceSpec(name: "a", machine: "M1Ultra")]))
        XCTAssertEqual(DeviceHostGrouping.resolve(RunDeviceRef(name: "a"), in: entries),
                       .ambiguous(hosts: ["local", "M1Ultra"]))
    }

    func testQualifiedRefPicksTheDeviceOnThatHost() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            ios: [DeviceSpec(name: "a", udid: "LOCAL"),
                  DeviceSpec(name: "a", machine: "M1Ultra", udid: "REMOTE")]))
        guard case .found(let entry) = DeviceHostGrouping.resolve(
            RunDeviceRef(name: "a", machine: "M1Ultra"), in: entries) else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(entry.spec.udid, "REMOTE")
    }

    /// `"host": "local"` は「未指定」ではなく「手元のもの」の明示指定。ここを normalize 後の
    /// nil と同一視すると、同名が2台あるときに曖昧扱いになって手元指定が書けなくなる
    func testExplicitLocalRefPicksTheLocalDeviceInsteadOfBeingAmbiguous() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            ios: [DeviceSpec(name: "a", udid: "LOCAL"),
                  DeviceSpec(name: "a", machine: "M1Ultra", udid: "REMOTE")]))
        guard case .found(let entry) = DeviceHostGrouping.resolve(
            RunDeviceRef(name: "a", machine: "local"), in: entries) else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(entry.spec.udid, "LOCAL")
    }

    func testQualifiedRefForAHostThatDoesNotHaveItIsMissing() {
        let entries = DeviceHostGrouping.entries(machine: machine(ios: [DeviceSpec(name: "a")]))
        XCTAssertEqual(DeviceHostGrouping.resolve(RunDeviceRef(name: "a", machine: "M1Ultra"),
                                                  in: entries), .missing)
    }

    // MARK: - workerID(ApiMonitorCommand.MonitorTarget.id / ApiRunHostFanout が共有する規則)

    func testWorkerIDOmitsTheHostWhenLocal() {
        XCTAssertEqual(DeviceHostGrouping.workerID(platform: "ios", host: nil, name: "iPhone A"),
                       "ios:iPhone A")
        XCTAssertEqual(DeviceHostGrouping.workerID(platform: "ios", host: "local", name: "iPhone A"),
                       "ios:iPhone A", "\"local\" は normalize で nil に畳まれるので手元と同じ形")
    }

    func testWorkerIDIncludesTheHostWhenRemote() {
        XCTAssertEqual(DeviceHostGrouping.workerID(platform: "android", host: "M1Max", name: "Pixel 10"),
                       "android:M1Max/Pixel 10")
    }

    func testGroupsKeepFirstAppearanceOrderAndSeparateLocalFromRemote() {
        let entries = DeviceHostGrouping.entries(machine: machine(
            ios: [DeviceSpec(name: "r1", machine: "M1Ultra"), DeviceSpec(name: "l1"),
                  DeviceSpec(name: "r2", machine: "M1Ultra"), DeviceSpec(name: "l2")]))
        let groups = DeviceHostGrouping.groups(entries) { $0.host }
        XCTAssertEqual(groups.map(\.host), ["M1Ultra", nil])
        XCTAssertEqual(groups.map { $0.devices.map(\.name) }, [["r1", "r2"], ["l1", "l2"]])
    }
}
