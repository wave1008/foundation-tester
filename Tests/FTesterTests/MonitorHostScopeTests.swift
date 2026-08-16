// モニターが「どの機械のデバイスを観測し、何を devices として出すか」の規則。
//
// 守っているのは3つ:
//  1. **他の機械のデバイスを走査しない** —— simctl/adb は手元にしか効かないので、走査すると
//     同名の手元のシミュレータに解決して**別の機械の台の状態と画面**を出す((host, name) が
//     一意なら同名は正常な構成なので普通に起きる)
//  2. **観測していない台を offline と言わない** —— 向こうで動いていても止まって見える
//     (2026-08-17 の実害。これが「起動しようとしたのか分からない」の正体)
//  3. **子(--device-host 付き)は自分のぶんだけを出す** —— 親も同じ台を並べるので、
//     両方が出すと拡張側の Map(id が鍵)で潰し合う

import FTCore
import XCTest

@testable import ftester

final class MonitorHostScopeTests: XCTestCase {

    private func target(_ name: String, host: String?, platform: String = "ios") -> MonitorTarget {
        var spec = DeviceSpec(name: name, os: "27.0")
        spec.host = host
        return MonitorTarget(platform: platform, spec: spec)
    }

    // MARK: - scope

    func testParentScansOnlyItsOwnDevicesButListsThemAll() {
        let targets = [target("A", host: nil), target("B", host: "M1Max"), target("C", host: "M1Ultra")]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceHost: nil)

        XCTAssertEqual(scope.owned.map(\.name), ["A"],
                       "他の機械の台を simctl/adb で見ると同名の手元の台に解決してしまう")
        XCTAssertEqual(scope.listed.map(\.name), ["A", "B", "C"],
                       "並べるのは全部(タイルが消えると、ホストが落ちた瞬間に台が画面から消える)")
        XCTAssertEqual(scope.foreignHosts, ["M1Max", "M1Ultra"])
    }

    func testChildOwnsTheHostItWasToldAndListsNothingElse() {
        let targets = [target("A", host: nil), target("B", host: "M1Max"), target("C", host: "M1Ultra")]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceHost: "M1Max")

        XCTAssertEqual(scope.owned.map(\.name), ["B"])
        XCTAssertEqual(scope.listed.map(\.name), ["B"], "親も同じ台を出すので、子が他を出すと潰し合う")
        XCTAssertTrue(scope.foreignHosts.isEmpty, "入れ子のディスパッチは作らない")
    }

    func testExplicitLocalCountsAsThisMachine() {
        let scope = ApiMonitorCommand.scope(targets: [target("A", host: "local")], deviceHost: nil)
        XCTAssertEqual(scope.owned.map(\.name), ["A"])
        XCTAssertTrue(scope.foreignHosts.isEmpty)
    }

    func testForeignHostsAreListedOnceInOrderOfAppearance() {
        let targets = [
            target("A", host: "M1Ultra"), target("B", host: "M1Max"), target("C", host: "M1Ultra"),
        ]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceHost: nil)
        XCTAssertEqual(scope.foreignHosts, ["M1Ultra", "M1Max"], "1ホストにつき子は1本")
    }

    // MARK: - mergedDevices

    private func info(id: String, state: String) -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(
            id: id, name: id, platform: "ios", state: state, detail: "", udid: nil, serial: nil,
            health: nil, renderMode: nil, inRun: false, kind: "virtual", host: nil, port: nil,
            recording: false, registered: true, machineHost: nil, frozen: false)
    }

    func testRemoteEntriesFillInForTheDevicesThisMachineCannotSee() {
        let targets = [target("A", host: nil), target("B", host: "M1Max")]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "connected")],
            remote: ["ios:M1Max/B": info(id: "ios:M1Max/B", state: "connected")])

        XCTAssertEqual(merged.map(\.id), ["ios:A", "ios:M1Max/B"], "並びはマシンプロファイルの順のまま")
        XCTAssertEqual(merged.map(\.state), ["connected", "connected"])
    }

    func testDevicesNobodyObservedAreUnknownNotOffline() {
        let targets = [target("A", host: nil), target("B", host: "M1Max")]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets, observed: [info(id: "ios:A", state: "offline")], remote: [:])

        XCTAssertEqual(merged.map(\.state), ["offline", "unknown"],
                       "届いていない台を offline と言うと、向こうで動いていても止まって見える")
        XCTAssertEqual(merged[1].machineHost, "M1Max", "どの機械に届いていないのかを言えること")
    }

    func testObservationWinsOverAStaleRemoteEntryForTheSameID() {
        let targets = [target("A", host: nil)]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "booted")],
            remote: ["ios:A": info(id: "ios:A", state: "connected")])
        XCTAssertEqual(merged.map(\.state), ["booted"], "手元で見えているものが正")
    }

    func testUnregisteredRunningDevicesAreAppendedAfterTheProfileOrder() {
        let targets = [target("A", host: nil)]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "connected"), info(id: "ios:stray", state: "connected")],
            remote: [:])
        XCTAssertEqual(merged.map(\.id), ["ios:A", "ios:stray"],
                       "マシンプロファイルに無い起動中デバイスも落とさない")
    }
}
