// ディスパッチ判定(`DeviceMachineRunner.plan` / `machineScopedDeviceFilter` /
// `resolveEffectiveDispatchTarget`)が実行プロファイルの devices[].machine だけから決まることを固定する。
// どれも resolve() より前に呼ばれるので、ここがズレると「配る先」と「実際に走る台」が食い違う。

import XCTest
import FTCore
@testable import fleetest

final class RunProfileMachineDispatchTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        try FileManager.default.createDirectory(at: project.runsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeRun(_ name: String, _ devices: String) throws {
        try "{ \"app\": \"a\", \"devices\": \(devices) }".data(using: .utf8)!
            .write(to: project.runsDir.appendingPathComponent("\(name).json"))
    }

    /// 手元 + リモート + 無効のリモート(別の機械)。無効の台は分割にも絞り込みにも入らない
    private func writeMixed() throws {
        try writeRun("multi", """
        [ { "platform": "ios", "machine": "local", "name": "ローカル機" },
          { "platform": "ios", "machine": "runner1", "name": "リモート機" },
          { "platform": "ios", "machine": "runner2", "name": "無効の機", "enabled": false } ]
        """)
    }

    func testPlanSplitsByMachineAndIgnoresDisabledDevices() throws {
        try writeMixed()
        let groups = try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: nil, deviceFilter: [], disabledMachines: [])
        XCTAssertEqual(groups?.map(\.machineLabel), ["local", "runner1"])
        XCTAssertEqual(groups?.map(\.deviceNames), [["ローカル機"], ["リモート機"]])
    }

    func testPlanIsNilWhenEveryEnabledDeviceIsOnOneMachine() throws {
        try writeRun("single", """
        [ { "platform": "ios", "machine": "runner1", "name": "a" },
          { "platform": "ios", "machine": "local", "name": "b", "enabled": false } ]
        """)
        XCTAssertNil(try DeviceMachineRunner.plan(
            project: project, profileName: "single", explicitHost: nil, deviceFilter: [], disabledMachines: []))
    }

    func testPlanIsNilWithAnExplicitRunner() throws {
        try writeMixed()
        XCTAssertNil(try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: "local", deviceFilter: [], disabledMachines: []))
    }

    // MARK: - マシン有効(MachineEnablement)

    /// 無効の機械を外して残りで分割する
    func testPlanSkipsDisabledMachines() throws {
        try writeRun("three", """
        [ { "platform": "ios", "machine": "local", "name": "l" },
          { "platform": "ios", "machine": "runner1", "name": "r1" },
          { "platform": "ios", "machine": "runner2", "name": "r2" } ]
        """)
        let groups = try DeviceMachineRunner.plan(
            project: project, profileName: "three", explicitHost: nil, deviceFilter: [],
            disabledMachines: ["runner1"])
        XCTAssertEqual(groups?.map(\.machineLabel), ["local", "runner2"])
    }

    /// 外した結果が1機械でも分割計画を返す(nil だと単一経路がプロファイル丸ごとを見て、
    /// 外した機械の台を手元で探す/外した機械へ自動ディスパッチする)
    func testPlanReturnsASingleGroupWhenDisablingLeavesOneMachine() throws {
        try writeMixed()
        let groups = try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: nil, deviceFilter: [],
            disabledMachines: ["runner1"])
        XCTAssertEqual(groups?.map(\.machineLabel), ["local"])
        XCTAssertEqual(groups?.map(\.deviceNames), [["ローカル機"]])
        let remoteOnly = try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: nil, deviceFilter: [],
            disabledMachines: ["local"])
        XCTAssertEqual(remoteOnly?.map(\.machineLabel), ["runner1"])
    }

    /// 無効の機械がプロファイルに居なければ従来どおり(単一機械なら nil)
    func testPlanIgnoresDisabledMachinesTheProfileDoesNotUse() throws {
        try writeRun("single", """
        [ { "platform": "ios", "machine": "runner1", "name": "a" } ]
        """)
        XCTAssertNil(try DeviceMachineRunner.plan(
            project: project, profileName: "single", explicitHost: nil, deviceFilter: [],
            disabledMachines: ["runner2", "local"]))
    }

    func testPlanRefusesWhenEveryMachineIsDisabled() throws {
        try writeRun("single", """
        [ { "platform": "ios", "machine": "runner1", "name": "a" } ]
        """)
        XCTAssertThrowsError(try DeviceMachineRunner.plan(
            project: project, profileName: "single", explicitHost: nil, deviceFilter: [],
            disabledMachines: ["runner1"])) { error in
            XCTAssertTrue("\(error)".contains("runner1"), "\(error)")
        }
    }

    /// 明示の --runner には効かない(機械分担・フリートの子は --runner 付きで起こされる)
    func testPlanIgnoresDisabledMachinesWithAnExplicitRunner() throws {
        try writeMixed()
        XCTAssertNil(try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: "runner1", deviceFilter: [],
            disabledMachines: ["runner1", "local"]))
    }

    func testFleetSkipsEntriesOnDisabledMachines() {
        let fleet = FleetProfileDocument(runs: [
            FleetRunEntry(host: "local", profile: "p"),
            FleetRunEntry(host: "runner1", profile: "p"),
            FleetRunEntry(host: "runner1", profile: "q"),
            FleetRunEntry(host: "runner2", profile: "p"),
        ])
        let (kept, skipped) = FleetRunner.excludingDisabledMachines(fleet, disabled: ["runner1", "local"])
        XCTAssertEqual(kept.runs.map(\.host), ["runner2"])
        XCTAssertEqual(skipped, ["local", "runner1"])
    }

    func testMachineScopedDeviceFilterPinsTheTargetMachinesDevices() throws {
        try writeMixed()
        let (names, machine) = try machineScopedDeviceFilter(
            project: project, profile: "multi", targetMachine: "runner1")
        XCTAssertEqual(names, ["リモート機"])
        XCTAssertEqual(machine, "runner1")
    }

    func testMachineScopedDeviceFilterRejectsAMachineWithNoDevices() throws {
        try writeMixed()
        XCTAssertThrowsError(try machineScopedDeviceFilter(
            project: project, profile: "multi", targetMachine: "runner2"))
    }

    /// 全台が1つのリモートに居れば `--runner` なしでそこへ自動ディスパッチする(登録名のみ受ける)
    func testEffectiveTargetAutoDispatchesWhenAllDevicesLiveOnOneRemote() throws {
        try writeRun("remote-only", """
        [ { "platform": "ios", "machine": "runner1", "name": "a" },
          { "platform": "android", "machine": "runner1", "name": "b" } ]
        """)
        let target = try resolveEffectiveDispatchTarget(
            explicitTarget: nil, profile: "remote-only", project: nil,
            requireProfileMachine: true, testProject: project)
        XCTAssertEqual(target?.rawTarget, "runner1")
        XCTAssertEqual(target?.requiresRegisteredName, true)
        XCTAssertEqual(target?.origin, .autoDispatch(machine: "runner1"))
    }

    func testEffectiveTargetStaysLocalForLocalOrMixedProfiles() throws {
        try writeMixed()
        try writeRun("local-only", #"[ { "platform": "ios", "machine": "local", "name": "a" } ]"#)
        for profile in ["multi", "local-only"] {
            XCTAssertNil(try resolveEffectiveDispatchTarget(
                explicitTarget: nil, profile: profile, project: nil,
                requireProfileMachine: true, testProject: project), profile)
        }
    }

    func testEffectiveTargetExplicitRunnerWinsAndLocalStaysLocal() throws {
        try writeRun("remote-only", #"[ { "platform": "ios", "machine": "runner1", "name": "a" } ]"#)
        let explicit = try resolveEffectiveDispatchTarget(
            explicitTarget: "user@other", profile: "remote-only", project: nil,
            requireProfileMachine: true, testProject: project)
        XCTAssertEqual(explicit?.rawTarget, "user@other")
        XCTAssertEqual(explicit?.requiresRegisteredName, false)
        XCTAssertNil(try resolveEffectiveDispatchTarget(
            explicitTarget: "local", profile: "remote-only", project: nil,
            requireProfileMachine: true, testProject: project))
    }

    func testEffectiveTargetIgnoresTheProfileWhenNotRequired() throws {
        try writeRun("remote-only", #"[ { "platform": "ios", "machine": "runner1", "name": "a" } ]"#)
        XCTAssertNil(try resolveEffectiveDispatchTarget(
            explicitTarget: nil, profile: "remote-only", project: nil,
            requireProfileMachine: false, testProject: project))
    }
}
