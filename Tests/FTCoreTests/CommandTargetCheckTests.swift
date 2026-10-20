// dry-run の「このデバイスでは動かないコマンド」の照合(FTCore.CommandTargetCheck)と、その表
// (`DSLCommandIndex.unsupportedTargets`)を縛る。

@testable import FTCore
import XCTest

final class CommandTargetCheckTests: XCTestCase {

    private let inappSim = CommandTargetCheck.Device(name: "iPhone-inapp", platform: "ios", engine: "inapp", physical: false)
    private let hybridSim = CommandTargetCheck.Device(name: "iPhone-hybrid", platform: "ios", engine: "hybrid", physical: false)
    private let iPhone = CommandTargetCheck.Device(name: "iPhone 13", platform: "ios", engine: "xcuitest", physical: true)
    private let pixel = CommandTargetCheck.Device(name: "Pixel", platform: "android", engine: nil, physical: true)

    private func step(_ command: String, line: Int = 1) -> CommandTargetCheck.Step {
        CommandTargetCheck.Step(command: command, file: "/p/scenarios/A.swift", line: line)
    }

    /// 表の行はすべて索引に実在する名前(改名で表だけ取り残されると、その行は黙って照合されなくなる)
    func testEveryTableEntryNamesAnIndexedCommand() {
        let names = Set(DSLCommandIndex.all.map(\.name))
        XCTAssertEqual(Set(DSLCommandIndex.unsupportedTargets.keys).subtracting(names), [])
    }

    /// 表そのものを固定する(docs/commands.md §`engine: inapp` 単独で失敗するコマンド と対)
    func testTableIsPinned() {
        let inapp = Set(DSLCommandIndex.unsupportedTargets.filter { $0.value.contains(.iosInAppEngine) }.keys)
        XCTAssertEqual(inapp, ["home", "back", "appSwitcher", "tapAppIcon", "fold", "unfold", "hinge",
                               "swipePointToPoint", "swipeBy", "swipeElementToElement", "hold", "gesture",
                               "waitForSettle"])
        let physical = Set(DSLCommandIndex.unsupportedTargets.filter { $0.value.contains(.iosPhysical) }.keys)
        XCTAssertEqual(physical, ["fold", "unfold", "hinge", "addMedia"])
        XCTAssertEqual(DSLCommandIndex.all.first { $0.name == "home" }?.unsupportedOn, [.iosInAppEngine])
        XCTAssertEqual(DSLCommandIndex.all.first { $0.name == "tap" }?.unsupportedOn, [])
    }

    func testDeviceTargets() {
        XCTAssertEqual(inappSim.targets, [.iosInAppEngine])
        XCTAssertEqual(hybridSim.targets, [])
        XCTAssertEqual(iPhone.targets, [.iosPhysical])
        XCTAssertEqual(CommandTargetCheck.Device(name: "x", platform: "ios", engine: "xcuitest", physical: false).targets, [])
        // Android にはエンジンの選択肢が無く、実機の条件も今は無い
        XCTAssertEqual(pixel.targets, [])
    }

    func testResolvedDeviceIsReadFromTheSpec() {
        let device = CommandTargetCheck.Device(ResolvedDevice(
            platform: "ios", spec: DeviceSpec(name: "phys", kind: .physical, engine: "xcuitest")))
        XCTAssertEqual(device, CommandTargetCheck.Device(name: "phys", platform: "ios", engine: "xcuitest", physical: true))
    }

    func testFindingsOnlyForDevicesOfTheScenarioPlatform() {
        let findings = CommandTargetCheck.findings(
            steps: [step("tap"), step("home", line: 2), step("addMedia", line: 3)],
            platform: "ios", devices: [hybridSim, inappSim, iPhone, pixel])
        XCTAssertEqual(findings, [
            .init(step: step("home", line: 2), device: "iPhone-inapp", target: .iosInAppEngine),
            .init(step: step("addMedia", line: 3), device: "iPhone 13", target: .iosPhysical),
        ])
        XCTAssertEqual(CommandTargetCheck.findings(steps: [step("home")], platform: "android",
                                                   devices: [inappSim, pixel]), [])
    }

    /// ループで同じ行を何度通っても1件。別の行なら別件
    func testSameStepIsCountedOnce() {
        let findings = CommandTargetCheck.findings(
            steps: [step("back"), step("back"), step("back", line: 9)], platform: "ios", devices: [inappSim])
        XCTAssertEqual(findings.map(\.step.line), [1, 9])
    }

    func testFoldOnAnInAppPhysicalStyleDeviceReportsEachReason() {
        let both = CommandTargetCheck.Device(name: "odd", platform: "ios", engine: "inapp", physical: true)
        let findings = CommandTargetCheck.findings(steps: [step("fold")], platform: "ios", devices: [both])
        XCTAssertEqual(findings.map(\.target), [.iosInAppEngine, .iosPhysical])
    }
}
