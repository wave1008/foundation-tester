// 機械分担の run は、手元の台の二重使用を**どの機械へも配る前に**断る
// (ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch)。実害(2026-09-17 負荷テスト M12):
// 手元分が「already in use」で断られた後にリモート3機のロックを取って残りを走らせ、
// 同時刻に始まった本来の run のリモート分を丸ごと弾いた。
// 台の鍵を simctl/adb を引かずに決めるため、手元の台は物理 iOS(udid の記載をそのまま使う)で組む。

import XCTest
@testable import FTCore
import FTBridgeClient
@testable import fleetest

final class LocalLeaseRefusalBeforeDispatchTests: XCTestCase {
    private var tempDir: URL!
    private var project: TestProject!
    private var stateDir: URL!

    /// 保持者として使える「自分でも親でもない、生きている pid」。launchd(1)は常に生きている
    private let otherLivePID: Int32 = 1

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalLeaseRefusal-\(UUID().uuidString)")
        project = TestProject(name: "P", rootURL: tempDir.appendingPathComponent("TestProjects/P"))
        stateDir = tempDir.appendingPathComponent(".fleetest")
        for dir in [project.appsDir, project.runsDir, stateDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try """
        { "ios": { "appName": "App", "app": "com.example.app" } }
        """.write(to: project.appsDir.appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
        try """
        { "app": "app",
          "devices": [
            { "platform": "ios", "machine": "local", "name": "A", "kind": "physical", "udid": "UA" },
            { "platform": "ios", "machine": "local", "name": "B", "kind": "physical", "udid": "UB" },
            { "platform": "ios", "machine": "M1Max", "name": "R", "kind": "physical", "udid": "UR" } ] }
        """.write(to: project.runsDir.appendingPathComponent("fleet.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func check(scenarios: Int) throws {
        try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
            project: project, profileName: "fleet", setOverrides: [:],
            localDeviceNames: ["A", "B"],
            localScenarios: (0..<scenarios).map { ScenarioInfo(id: "C.S\($0)", title: "t") },
            broadcast: false, leaseStateDir: stateDir)
    }

    /// 手元の台を別の生きた run が握っていれば、台と保持者を名指しして断る
    func testRefusesWhenALocalDeviceIsHeldByAnotherRun() {
        RunLease.write(stateDir: stateDir, key: "UA", pid: otherLivePID)
        XCTAssertThrowsError(try check(scenarios: 1)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("already in use by another fleetest run"), message)
            XCTAssertTrue(message.contains("held by pid \(otherLivePID)"), message)
            XCTAssertTrue(message.contains("Nothing was dispatched to the other machines"), message)
        }
    }

    /// 誰も握っていなければ通す
    func testPassesWhenNoLocalDeviceIsHeld() {
        XCTAssertNoThrow(try check(scenarios: 1))
    }

    /// 別の機械の台(R)の lease はこの機械の判定に数えない(その機械の子が自分で見る)
    func testIgnoresLeasesOfDevicesOnOtherMachines() {
        RunLease.write(stateDir: stateDir, key: "UR", pid: otherLivePID)
        XCTAssertNoThrow(try check(scenarios: 2))
    }

    /// 自分の pid の lease は衝突にしない(同じプロセスが先に書いた形)
    func testIgnoresItsOwnLease() {
        RunLease.write(stateDir: stateDir, key: "UA", pid: getpid())
        XCTAssertNoThrow(try check(scenarios: 2))
    }

    /// 手元に回るシナリオが無ければ判定しない(手元の子を起こさない)
    func testDoesNothingWithoutLocalScenarios() {
        RunLease.write(stateDir: stateDir, key: "UA", pid: otherLivePID)
        XCTAssertNoThrow(try check(scenarios: 0))
    }

    /// 配線: 2 経路とも**子の起動より前**に呼ぶ(型では守れないのでソースで固定する)
    func testBothFanoutsCheckBeforeLaunchingChildren() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (path, launch) in [("Sources/fleetest/DeviceMachineRunner.swift", "FleetRunner.runEntry("),
                               ("Sources/fleetest/ApiRunMachineFanout.swift", "ApiRunStartedEvent(total: selected")] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let guardCall = try XCTUnwrap(text.range(of: "try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch("),
                                          "\(path) must call the guard")
            let launchCall = try XCTUnwrap(text.range(of: launch), "\(path): \(launch) not found")
            XCTAssertLessThan(guardCall.lowerBound, launchCall.lowerBound, path)
        }
    }
}
