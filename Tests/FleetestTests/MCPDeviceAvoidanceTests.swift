// MCP(fleetest-mcp)が操作している台を run が黙って奪わない(ユーザー決定「避けて、足りなければ警告して使う」):
// ①MCP は台を指すツールのたびに `.fleetest/mcp-<鍵>.lease` へ自分の pid を書く
// ②run は回す本数に絞るとき印のある台を後回しにし、それでも使う台は警告で名指しする
// ③MCP は run の lease がある台を触ったら応答の先頭で言う(断らない)
// 台の鍵を simctl/adb を引かずに決めるため、ここでは物理 iOS(udid の記載をそのまま使う)で組む。

import XCTest
@testable import FTCore
import FTBridgeClient
@testable import fleetest

final class MCPDeviceAvoidanceTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPDeviceAvoidanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func phone(_ name: String, udid: String) -> ResolvedDevice {
        ResolvedDevice(platform: "ios", spec: DeviceSpec(name: name, kind: .physical, udid: udid))
    }

    private func profile(_ devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "r", machineName: "m", appName: "app", apps: [:],
            devices: devices, fm: FMConfig(),
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosFastInput: false, iosPreActionWarmup: true, containerInference: true, ocr: true,
            ocrFalsePositiveCheck: true, enableAnimations: false,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    /// 印の保持者として使える「自分でも親でもない、生きている pid」。launchd(1)は常に生きている
    private let otherLivePID: Int32 = 1

    // MARK: - 純粋関数(FTCore)

    func testDeprioritizedDevicesAreTrimmedFirst() {
        let a = phone("A", udid: "UA"), b = phone("B", udid: "UB"), c = phone("C", udid: "UC")
        let kept = profile([a, b, c]).limitingDevices(iosScenarios: 1, androidScenarios: 0,
                                                      deprioritizing: { $0 == a })
        XCTAssertEqual(kept.devices.map(\.name), ["B", "C"], "1本 + 予備1台 = 2台。MCP の A を後回しにする")
    }

    func testDeprioritizedDevicesAreStillUsedWhenNothingElseIsFree() {
        let a = phone("A", udid: "UA"), b = phone("B", udid: "UB")
        let kept = profile([a, b]).limitingDevices(iosScenarios: 5, androidScenarios: 0,
                                                   deprioritizing: { $0 == a })
        XCTAssertEqual(Set(kept.devices.map(\.name)), ["A", "B"])
    }

    // MARK: - 印の読み取り

    func testLiveHoldersSkipsExcludedAndDeadPIDs() {
        MCPDeviceLease.write(stateDir: stateDir, key: "UA", pid: otherLivePID)
        MCPDeviceLease.write(stateDir: stateDir, key: "UB", pid: getpid())
        MCPDeviceLease.write(stateDir: stateDir, key: "UC", pid: 99_999_9)
        XCTAssertEqual(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: [getpid()]), ["UA": otherLivePID])
    }

    // MARK: - run 側

    /// **本命**: MCP が A を操作中なら、2台で足りる run は A を使わず、警告も出ない
    func testRunAvoidsTheDeviceTheMCPIsDriving() {
        MCPDeviceLease.write(stateDir: stateDir, key: "UA", pid: otherLivePID)
        let (resolved, warnings) = ProfileRunner.limitingDevicesAvoidingMCP(
            profile([phone("A", udid: "UA"), phone("B", udid: "UB"), phone("C", udid: "UC")]),
            iosScenarios: 1, androidScenarios: 0, trim: true, leaseStateDir: stateDir)
        XCTAssertEqual(resolved.devices.map(\.name), ["B", "C"])
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    /// 足りないときは使い、MCP の pid を名指しして警告する
    func testRunWarnsWhenItMustTakeTheMCPDevice() {
        MCPDeviceLease.write(stateDir: stateDir, key: "UA", pid: otherLivePID)
        let (resolved, warnings) = ProfileRunner.limitingDevicesAvoidingMCP(
            profile([phone("A", udid: "UA"), phone("B", udid: "UB")]),
            iosScenarios: 5, androidScenarios: 0, trim: true, leaseStateDir: stateDir)
        XCTAssertEqual(Set(resolved.devices.map(\.name)), ["A", "B"])
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        let warning = warnings.first ?? ""
        XCTAssertTrue(warning.contains("A is being driven by an MCP session (pid \(otherLivePID))"), warning)
    }

    /// 自分(と親)の印は数えない(MCP が起こした run が自分を「MCP が操作中」と言わない)
    func testRunIgnoresItsOwnProcessesLease() {
        MCPDeviceLease.write(stateDir: stateDir, key: "UA", pid: getpid())
        let (resolved, warnings) = ProfileRunner.limitingDevicesAvoidingMCP(
            profile([phone("A", udid: "UA"), phone("B", udid: "UB"), phone("C", udid: "UC")]),
            iosScenarios: 1, androidScenarios: 0, trim: true, leaseStateDir: stateDir)
        XCTAssertEqual(resolved.devices.map(\.name), ["A", "B"])
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }
}
