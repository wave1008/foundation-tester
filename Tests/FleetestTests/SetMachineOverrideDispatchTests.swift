// 欠陥②(2026-09-08): `--set machine=...` は `ProfileResolver.resolve` では効くが、
// ディスパッチ判定(`DeviceMachineRunner.plan` / `machineScopedDeviceFilter` — どちらも内部で
// `ProfileResolver.determineMachine` を呼ぶ)は上書き前の値のままだった。結果として「別マシンの
// デバイスを解決しつつ実行は元マシンのまま」になり "no simulator with that UDID" で止まる。
// ここでは両関数へ `overrides` を通すと同じ machine を見ることを、2つのマシンプロファイルが
// 存在して自動決定できない(= 上書きが無いと `machineUndetermined` で落ちる/黙って無効化される)
// 状況を使って固定する。

import XCTest
import FTCore
@testable import fleetest

final class SetMachineOverrideDispatchTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, to dir: URL, name: String) throws {
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    /// machines/ に2ファイル(A・B)を置き、実行プロファイル自身は machine 未指定にする ——
    /// `determineMachine` は overrides が無ければ `machineUndetermined` で落ちる、という
    /// 一意な「上書きが効いたかどうか」の witness を作る。A はローカル台+リモート台(machine 混在)
    /// を1台ずつ持つ
    private func writeAmbiguousMachinesFixture() throws {
        try write("""
        { "ios": { "devices": [
              { "name": "ローカル機", "simulator": "iPhone 17 Pro" },
              { "name": "リモート機", "machine": "runner1", "simulator": "iPhone 17 Pro" } ] } }
        """, to: project.machinesDir, name: "A")
        try write("{}", to: project.machinesDir, name: "B")
        try write("""
        { "devices": [ { "name": "ローカル機" }, { "name": "リモート機" } ] }
        """, to: project.runsDir, name: "multi")
    }

    /// **誤って指定された machine は黙って無視しない**。ディスパッチ経路はこの後 resolve() を
    /// 通らずそのまま dispatch するので、飲み込むと指定が消えたままリモートへ飛ぶ
    func testMachineScopedDeviceFilterThrowsWhenTheNamedMachineDoesNotExist() throws {
        try writeAmbiguousMachinesFixture()
        XCTAssertThrowsError(
            try machineScopedDeviceFilter(project: project, profile: "multi",
                                          targetMachine: "runner1",
                                          overrides: ["machine": .string("存在しない機")])
        ) { error in
            guard case ProfileError.runSpecifiedMachineNotFound = error else {
                return XCTFail("runSpecifiedMachineNotFound のはず: \(error)")
            }
        }
    }

    /// 逆向き: **誰も指定していない**ときは従来どおり絞らずに通す(リモートが自分の
    /// machines/ で決められるため)。片方向だけだと「常に投げる」変異を素通しする
    func testMachineScopedDeviceFilterFallsBackWhenMachineIsAmbiguous() throws {
        try writeAmbiguousMachinesFixture()
        // overrides 無し: determineMachine が machineUndetermined で失敗し、
        // machineScopedDeviceFilter はフォールバックする(対照)
        let (names, machine) = try machineScopedDeviceFilter(
            project: project, profile: "multi", targetMachine: "runner1")
        XCTAssertEqual(names, [])
        XCTAssertNil(machine)
    }

    func testMachineScopedDeviceFilterHonorsSetMachineOverride() throws {
        try writeAmbiguousMachinesFixture()
        let (names, machine) = try machineScopedDeviceFilter(
            project: project, profile: "multi", targetMachine: "runner1",
            overrides: ["machine": .string("A")])
        XCTAssertEqual(names, ["リモート機"], "上書き後の machine(A)のデバイス台帳で絞り込むはず")
        XCTAssertEqual(machine, "runner1")
    }

    func testDeviceMachineRunnerPlanFailsWithoutOverrideOnAmbiguousMachines() throws {
        try writeAmbiguousMachinesFixture()
        XCTAssertThrowsError(try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: nil, deviceFilter: [])) { error in
            guard case ProfileError.machineUndetermined = error else {
                return XCTFail("machineUndetermined のはず: \(error)")
            }
        }
    }

    func testDeviceMachineRunnerPlanHonorsSetMachineOverride() throws {
        try writeAmbiguousMachinesFixture()
        let groups = try DeviceMachineRunner.plan(
            project: project, profileName: "multi", explicitHost: nil, deviceFilter: [],
            overrides: ["machine": .string("A")])
        let labels = Set((groups ?? []).map(\.machineLabel))
        XCTAssertEqual(labels, ["local", "runner1"],
                       "上書き後の machine(A)は local/runner1 に分かれるはず: \(String(describing: groups))")
    }
}
