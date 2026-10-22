// dry-run の「このデバイスでは動かないコマンド」の照合(FTCore.CommandTargetCheck)と、その表
// (`DSLCommandIndex.unsupportedTargets`)を縛る。

@testable import FTCore
import XCTest

final class CommandTargetCheckTests: XCTestCase {

    private let sim = CommandTargetCheck.Device(name: "iPhone-sim", platform: "ios", physical: false)
    private let iPhone = CommandTargetCheck.Device(name: "iPhone 13", platform: "ios", physical: true)
    private let pixel = CommandTargetCheck.Device(name: "Pixel", platform: "android", physical: true)

    private func step(_ command: String, line: Int = 1) -> CommandTargetCheck.Step {
        CommandTargetCheck.Step(command: command, file: "/p/scenarios/A.swift", line: line)
    }

    /// 表の行はすべて索引に実在する名前(改名で表だけ取り残されると、その行は黙って照合されなくなる)
    func testEveryTableEntryNamesAnIndexedCommand() {
        let names = Set(DSLCommandIndex.all.map(\.name))
        XCTAssertEqual(Set(DSLCommandIndex.unsupportedTargets.keys).subtracting(names), [])
    }

    /// 表そのものを固定する
    func testTableIsPinned() {
        XCTAssertEqual(CommandUnsupportedTarget.allCases, [.iosPhysical])
        let physical = Set(DSLCommandIndex.unsupportedTargets.filter { $0.value.contains(.iosPhysical) }.keys)
        XCTAssertEqual(physical, ["fold", "unfold", "hinge", "addMedia"])
        XCTAssertEqual(DSLCommandIndex.all.first { $0.name == "fold" }?.unsupportedOn, [.iosPhysical])
        XCTAssertEqual(DSLCommandIndex.all.first { $0.name == "home" }?.unsupportedOn, [])
    }

    func testDeviceTargets() {
        XCTAssertEqual(sim.targets, [])
        XCTAssertEqual(iPhone.targets, [.iosPhysical])
        // Android には実機の条件も今は無い
        XCTAssertEqual(pixel.targets, [])
    }

    func testResolvedDeviceIsReadFromTheSpec() {
        let device = CommandTargetCheck.Device(ResolvedDevice(
            platform: "ios", spec: DeviceSpec(name: "phys", kind: .physical, mode: "xcuitest")))
        XCTAssertEqual(device, CommandTargetCheck.Device(name: "phys", platform: "ios", physical: true))
    }

    func testFindingsOnlyForDevicesOfTheScenarioPlatform() {
        let findings = CommandTargetCheck.findings(
            steps: [step("tap"), step("home", line: 2), step("addMedia", line: 3)],
            platform: "ios", devices: [sim, iPhone, pixel])
        XCTAssertEqual(findings, [
            .init(step: step("addMedia", line: 3), device: "iPhone 13", target: .iosPhysical),
        ])
        XCTAssertEqual(CommandTargetCheck.findings(steps: [step("addMedia")], platform: "android",
                                                   devices: [iPhone, pixel]), [])
    }

    /// ループで同じ行を何度通っても1件。別の行なら別件
    func testSameStepIsCountedOnce() {
        let findings = CommandTargetCheck.findings(
            steps: [step("fold"), step("fold"), step("fold", line: 9)], platform: "ios", devices: [iPhone])
        XCTAssertEqual(findings.map(\.step.line), [1, 9])
    }
}
