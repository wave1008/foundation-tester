// DeviceBooter.shutdownAll(一括停止の共通実装。devices down --profile / api stop-all-devices が
// 使う)の契約を stopOne 注入で固定する。デバイス実体には触れない(純粋な配線の検証)。
// stopOne は緑の run では1度も失敗しないので、失敗の分岐はここでしか通せない。

import XCTest
@testable import FTAndroid
import FTCore
import FTTestSupport

final class DeviceBooterShutdownAllTests: XCTestCase {

    private struct StopError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { label }
    }

    private func machine(ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineProfile {
        MachineProfile(
            ios: ios.isEmpty ? nil : MachineDeviceList(devices: ios),
            android: android.isEmpty ? nil : MachineDeviceList(devices: android))
    }

    func testAllDevicesStoppingSucceedsReportsNoFailures() async {
        let profile = machine(
            ios: [DeviceSpec(name: "iPhone-A", kind: .virtual)],
            android: [DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a")])
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in }, stopOne: { _, _ in })

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
        XCTAssertTrue(summary.failedNames.isEmpty)
        XCTAssertFalse(summary.allFailed)
    }

    func testEveryDeviceFailingToStopIsAllFailed() async {
        let profile = machine(
            ios: [DeviceSpec(name: "iPhone-A", kind: .virtual)],
            android: [DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a")])
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in },
            stopOne: { spec, _ in throw StopError(label: "\(spec.name) failed") })

        let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
        XCTAssertTrue(summary.allFailed)
        XCTAssertEqual(Set(summary.failedNames), Set(["iPhone-A", "Pixel-A"]))
    }

    func testPartialFailureToStopIsNotAllFailed() async {
        let profile = machine(
            ios: [DeviceSpec(name: "iPhone-A", kind: .virtual)],
            android: [DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a")])
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in },
            stopOne: { spec, _ in
                if spec.name == "Pixel-A" { throw StopError(label: "boom") }
            })

        let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
        XCTAssertFalse(summary.allFailed)
        XCTAssertEqual(summary.failedNames, ["Pixel-A"])
    }

    /// 実機は端末が生き続けるので deviceStopping/deviceFinished を出すとタイルがちらつく
    /// (「停止した」→次の観測で「接続中」に戻る)。**outcomes には実機も含める**
    /// (停止を試みた台の母数に入るため。要約の分母がここで狂うと全滅判定がずれる)
    func testProgressIsNotEmittedForPhysicalDevices() async {
        let profile = machine(
            ios: [DeviceSpec(name: "iPhone-Virtual", kind: .virtual),
                  DeviceSpec(name: "iPhone-Real", kind: .physical, udid: "00008130-AAAA")],
            android: [DeviceSpec(name: "Pixel-Real", kind: .physical, serial: "R3CN123")])
        let stopping = LockedBox([String]())
        let finished = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in },
            deviceStopping: { name, _ in stopping.mutate { $0.append(name) } },
            deviceFinished: { name, _ in finished.mutate { $0.append(name) } },
            stopOne: { _, _ in })

        XCTAssertEqual(stopping.value, ["iPhone-Virtual"])
        XCTAssertEqual(finished.value, ["iPhone-Virtual"])
        XCTAssertEqual(Set(outcomes.map(\.name)),
                       Set(["iPhone-Virtual", "iPhone-Real", "Pixel-Real"]),
                       "実機も試みた台の母数として outcomes に含める")
    }

    /// 拡張の再スキャン契約: stopOne が throw しても deviceFinished は必ず呼ばれる
    func testFinishedIsEmittedEvenWhenTheStopThrows() async {
        let profile = machine(ios: [DeviceSpec(name: "iPhone-A", kind: .virtual)])
        let finished = LockedBox([String]())
        _ = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in },
            deviceFinished: { name, _ in finished.mutate { $0.append(name) } },
            stopOne: { _, _ in throw StopError(label: "boom") })

        XCTAssertEqual(finished.value, ["iPhone-A"])
    }

    func testDevicesAreStoppedIosThenAndroid() async {
        let profile = machine(
            ios: [DeviceSpec(name: "iPhone-A", kind: .virtual)],
            android: [DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a")])
        let order = LockedBox([String]())
        _ = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, log: { _ in },
            stopOne: { spec, _ in order.mutate { $0.append(spec.name) } })

        XCTAssertEqual(order.value, ["iPhone-A", "Pixel-A"])
    }
}
