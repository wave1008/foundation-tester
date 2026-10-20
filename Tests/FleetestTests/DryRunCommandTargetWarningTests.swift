// dry-run の「このデバイスでは動かないコマンド」の警告文と、2実装(`fleetest run` / `fleetest api run`)の配線。

@testable import fleetest
import FTCore
import XCTest

final class DryRunCommandTargetWarningTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testStepIsTakenFromTheCommandFieldOfStepEvents() {
        var event = ScenarioEvent(kind: "step")
        event.command = "home"
        event.file = "/p/A.swift"
        event.line = 4
        XCTAssertEqual(DryRunTargetWarnings.step(from: event),
                       CommandTargetCheck.Step(command: "home", file: "/p/A.swift", line: 4))
        event.kind = "sceneStarted"
        XCTAssertNil(DryRunTargetWarnings.step(from: event))
        var noCommand = ScenarioEvent(kind: "step")
        noCommand.description = "home()"
        XCTAssertNil(DryRunTargetWarnings.step(from: noCommand), "description から切り出さない")
    }

    func testDevicesSharingAStepAndReasonAreOneLine() {
        let step = CommandTargetCheck.Step(command: "home", file: "/p/scenarios/A.swift", line: 4)
        let lines = DryRunTargetWarnings.lines(scenarioID: "A.s1", findings: [
            .init(step: step, device: "sim-1", target: .iosInAppEngine),
            .init(step: step, device: "sim-2", target: .iosInAppEngine),
        ])
        XCTAssertEqual(lines, [
            "⚠️ A.s1: home at A.swift:4 cannot run on devices \"sim-1\", \"sim-2\" — its engine is inapp,"
                + " which cannot hand this command to XCUITest (use hybrid or xcuitest for that device)",
        ])
        let physical = DryRunTargetWarnings.lines(scenarioID: "A.s1", findings: [
            .init(step: CommandTargetCheck.Step(command: "addMedia", file: nil, line: nil),
                  device: "iPhone 13", target: .iosPhysical),
        ])
        XCTAssertEqual(physical, [
            "⚠️ A.s1: addMedia cannot run on device \"iPhone 13\" — it is a physical iPhone, which this command cannot drive",
        ])
        XCTAssertEqual(DryRunTargetWarnings.lines(scenarioID: "A.s1", findings: []), [])
    }

    /// 2実装の片方だけに照合が入ると、もう片方の dry-run は黙って照合しない(RunCommandFlagParityTests と同じ理由)
    func testBothDryRunPathsRunTheCheck() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("DryRunTargetWarnings.step(from: event)"), "\(path) がステップを集めていない")
            XCTAssertTrue(source.contains("CommandTargetCheck.findings("), "\(path) が照合していない")
            XCTAssertTrue(source.contains(".map(CommandTargetCheck.Device.init)"), "\(path) がプロファイルのデバイスを渡していない")
        }
        // api run の `resolved` は本数で絞った後(明示 ID 1本なら 2 台)なので、照合は絞る前の `full` から取る
        let api = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/fleetest/ApiRunCommand.swift"),
                             encoding: .utf8)
        XCTAssertTrue(api.contains("commandCheckDevices = full.devices.map(CommandTargetCheck.Device.init)"),
                      "api run が絞る前のデバイスで照合していない")
        XCTAssertFalse(api.contains("devices: resolved.devices.map(CommandTargetCheck.Device.init)"),
                       "api run が本数で絞った後のデバイスで照合している")
    }
}
