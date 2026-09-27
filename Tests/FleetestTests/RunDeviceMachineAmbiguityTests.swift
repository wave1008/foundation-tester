// `RunDeviceMachineAmbiguity`(--device の名前が2つ以上の機械に当たるときの断り。CLAUDE.md
// 「fleetest run --profile P --device <名前> は同名デバイスのある全機械で回ってしまう」対策)の
// 純粋関数を単体で固定する。期待値はリテラル(production の定数を再利用しない)。

import XCTest
import FTCore
@testable import fleetest

final class RunDeviceMachineAmbiguityTests: XCTestCase {

    private func device(_ machine: String?, _ name: String) -> RunDeviceMachine {
        RunDeviceMachine(machine: machine, name: name, platform: "ios")
    }

    // MARK: - ambiguousNames(純粋な判定)

    /// 1つの機械にしか居ない名前は含めない
    func testOneMachineIsNotAmbiguous() {
        let devices = [device(nil, "iPhone-01"), device("M1Max", "iPhone-02")]
        XCTAssertEqual(
            RunDeviceMachineAmbiguity.ambiguousNames(deviceNames: ["iPhone-01"], devices: devices), [])
    }

    /// 2つ以上の機械に居る名前は、機械の一覧(表示名。ローカルは "local")付きで返す
    func testTwoOrMoreMachinesIsAmbiguous() {
        let devices = [device(nil, "iPhone-01"), device("M1Max", "iPhone-01"), device("M1Ultra", "iPhone-01")]
        let result = RunDeviceMachineAmbiguity.ambiguousNames(deviceNames: ["iPhone-01"], devices: devices)
        XCTAssertEqual(result, [RunDeviceMachineAmbiguity.Ambiguity(
            name: "iPhone-01", machines: ["local", "M1Max", "M1Ultra"])])
    }

    /// 複数の名前を渡したうち、曖昧なものだけを返す(曖昧でないものは混ぜない)
    func testOnlyTheAmbiguousNameAmongSeveralIsReported() {
        let devices = [
            device(nil, "iPhone-01"), device("M1Max", "iPhone-01"),  // 曖昧
            device(nil, "iPhone-02"),                                 // 曖昧でない
        ]
        let result = RunDeviceMachineAmbiguity.ambiguousNames(
            deviceNames: ["iPhone-01", "iPhone-02"], devices: devices)
        XCTAssertEqual(result, [RunDeviceMachineAmbiguity.Ambiguity(
            name: "iPhone-01", machines: ["local", "M1Max"])])
    }

    /// プロファイルに無い名前は「見つからない」の既存判定に任せる(空)
    func testNameNotInProfileIsEmpty() {
        let devices = [device(nil, "iPhone-01")]
        XCTAssertEqual(
            RunDeviceMachineAmbiguity.ambiguousNames(deviceNames: ["no-such-device"], devices: devices), [])
    }

    // MARK: - rejectionMessage(4条件のゲート)

    private let ambiguousDevices = [
        RunDeviceMachine(machine: nil, name: "iPhone-01", platform: "ios"),
        RunDeviceMachine(machine: "M1Max", name: "iPhone-01", platform: "ios"),
    ]

    /// 4条件が全部揃って初めて断る(--device あり・--runner/--device-machine/--all-machines 無し)
    func testRejectsWhenAmbiguousAndNothingElseGiven() {
        let message = RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: ["iPhone-01"], runner: nil, deviceMachine: nil, allMachines: false,
            devices: ambiguousDevices)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("iPhone-01"))
        XCTAssertTrue(message!.contains("local"))
        XCTAssertTrue(message!.contains("M1Max"))
    }

    func testDoesNotRejectWithExplicitRunner() {
        XCTAssertNil(RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: ["iPhone-01"], runner: "local", deviceMachine: nil, allMachines: false,
            devices: ambiguousDevices))
    }

    func testDoesNotRejectWithExplicitDeviceMachine() {
        XCTAssertNil(RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: ["iPhone-01"], runner: nil, deviceMachine: "M1Max", allMachines: false,
            devices: ambiguousDevices))
    }

    func testDoesNotRejectWithAllMachines() {
        XCTAssertNil(RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: ["iPhone-01"], runner: nil, deviceMachine: nil, allMachines: true,
            devices: ambiguousDevices))
    }

    /// --device が無ければ、そもそも「どの名前が曖昧か」を言う材料が無い
    func testDoesNotRejectWithNoDeviceFilter() {
        XCTAssertNil(RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: [], runner: nil, deviceMachine: nil, allMachines: false,
            devices: ambiguousDevices))
    }

    /// 陰性対照: 曖昧でない名前は4条件が揃っていても断らない
    func testDoesNotRejectWhenNotAmbiguous() {
        XCTAssertNil(RunDeviceMachineAmbiguity.rejectionMessage(
            deviceNames: ["iPhone-02"], runner: nil, deviceMachine: nil, allMachines: false,
            devices: [RunDeviceMachine(machine: nil, name: "iPhone-02", platform: "ios")]))
    }

    // MARK: - allMachinesConflictMessage

    func testAllMachinesConflictsWithRunner() {
        XCTAssertNotNil(RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: true, runner: "M1Max", deviceMachine: nil))
        XCTAssertNotNil(RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: true, runner: "local", deviceMachine: nil))
    }

    func testAllMachinesConflictsWithDeviceMachine() {
        XCTAssertNotNil(RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: true, runner: nil, deviceMachine: "local"))
    }

    func testAllMachinesAloneDoesNotConflict() {
        XCTAssertNil(RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: true, runner: nil, deviceMachine: nil))
    }

    /// --all-machines が無ければ、--runner/--device-machine があっても衝突ではない(通常の実行)
    func testNoConflictWhenAllMachinesNotGiven() {
        XCTAssertNil(RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: false, runner: "M1Max", deviceMachine: "M1Max"))
    }
}
