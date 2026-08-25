// 実行プロファイルの開始/終了スクリプト(docs/remote-runner.md §17)の純粋ロジック。
// 実際の起動・孤児の回収は Sources/fleetest/RunHookRunner.swift(プロセス起動が要るのでここでは扱わない)。

import Foundation
import XCTest
@testable import FTCore

final class RunHookPlanTests: XCTestCase {
    let workspace = URL(fileURLWithPath: "/repo/TestProjects/SampleApp/workspace")

    // MARK: - resolve: 名前も置き場所も固定(プロファイルに書く項目は無い)

    func testScriptsResolveUnderTheWorkspaceScriptsFolder() {
        XCTAssertEqual(RunHookPlan.resolve(kind: .setup, workspaceRoot: workspace).url.path,
                       "/repo/TestProjects/SampleApp/workspace/scripts/setup.sh")
        XCTAssertEqual(RunHookPlan.resolve(kind: .teardown, workspaceRoot: workspace).url.path,
                       "/repo/TestProjects/SampleApp/workspace/scripts/teardown.sh")
    }

    // MARK: - action: あれば実行、無ければ何もしない

    func testExistingScriptRuns() {
        let hook = RunHookPlan.resolve(kind: .setup, workspaceRoot: workspace)
        XCTAssertEqual(RunHookPlan.action(for: hook, exists: true), .run)
    }

    func testMissingScriptIsSkippedSilently() {
        let hook = RunHookPlan.resolve(kind: .teardown, workspaceRoot: workspace)
        XCTAssertEqual(RunHookPlan.action(for: hook, exists: false), .skip)
    }
}

final class RunHookEnvironmentTests: XCTestCase {

    func testKeysArePresentEvenWhenTheValuesAreUnknown() {
        let info = RunHookLeaseInfo(
            pid: 42, project: "SampleApp", profile: "android-1",
            teardown: "/ws/scripts/teardown.sh", workspace: "/ws", startedAt: "2026-08-18T00:00:00Z")
        let env = RunHookEnvironment.variables(orphan: info)
        // 回収経路は run の文脈を持たないが、キーを落とすと利用者の `set -u` が落ちる
        for key in ["FT_HOOK", "FT_WORKSPACE", "FT_PROJECT", "FT_PROFILE", "FT_MACHINE",
                    "FT_REPORT_DIR", "FT_IOS_DEVICES", "FT_ANDROID_DEVICES"] {
            XCTAssertNotNil(env[key], key)
        }
        XCTAssertEqual(env["FT_HOOK"], "teardown")
        XCTAssertEqual(env["FT_WORKSPACE"], "/ws")
        XCTAssertEqual(env["FT_PROFILE"], "android-1")
        XCTAssertEqual(env["FT_MACHINE"], "")
    }

    func testDeviceNamesAreSpaceSeparated() {
        let env = RunHookEnvironment.variables(
            kind: .setup, workspace: URL(fileURLWithPath: "/ws"), project: "P", profile: "r",
            machine: "m", reportDir: URL(fileURLWithPath: "/ws/reports"),
            iosDevices: ["sim1", "sim2"], androidDevices: ["emu1"])
        XCTAssertEqual(env["FT_IOS_DEVICES"], "sim1 sim2")
        XCTAssertEqual(env["FT_ANDROID_DEVICES"], "emu1")
        XCTAssertEqual(env["FT_REPORT_DIR"], "/ws/reports")
    }
}

final class RunHookLeaseTests: XCTestCase {

    func testRoundTrip() throws {
        let info = RunHookLeaseInfo.now(
            pid: 7, project: "SampleApp", profile: "android-1",
            teardown: URL(fileURLWithPath: "/ws/scripts/teardown.sh"),
            workspace: URL(fileURLWithPath: "/ws"),
            date: Date(timeIntervalSince1970: 0))
        let encoded = try XCTUnwrap(RunHookLease.encode(info))
        XCTAssertEqual(RunHookLease.decode(encoded), info)
        XCTAssertTrue(encoded.contains("1970-01-01T00:00:00Z"), encoded)
    }

    func testLeasePathIsProjectIndependent() {
        let stateDir = URL(fileURLWithPath: "/repo/.fleetest")
        XCTAssertEqual(RunHookLease.leaseURL(stateDir: stateDir, pid: 12).path,
                       "/repo/.fleetest/hooks/12.json")
    }

    func testALiveProcessIsNotAnOrphan() {
        let info = RunHookLeaseInfo(
            pid: 100, project: "P", profile: "r", teardown: "/t.sh", workspace: "/ws", startedAt: "")
        XCTAssertFalse(RunHookLease.isOrphan(info) { _ in true })
        XCTAssertTrue(RunHookLease.isOrphan(info) { _ in false })
    }

    func testABrokenRecordIsReapedSoItCannotAccumulate() {
        let info = RunHookLeaseInfo(
            pid: 0, project: "P", profile: "r", teardown: "/t.sh", workspace: "/ws", startedAt: "")
        XCTAssertTrue(RunHookLease.isOrphan(info) { _ in true })
    }

    /// 自分自身は必ず生きている = 走っている run の lease を自分で回収してしまわない
    func testTheCurrentProcessIsAlive() {
        XCTAssertTrue(RunHookLease.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    }

    func testAProcessThatDoesNotExistIsNotAlive() {
        // 使われていない大きな pid(macOS の既定上限 99999 の外)
        XCTAssertFalse(RunHookLease.processIsAlive(999_999))
        XCTAssertFalse(RunHookLease.processIsAlive(0))
        XCTAssertFalse(RunHookLease.processIsAlive(-1))
    }

    /// **ゾンビは死んだ扱い**。`kill(pid, 0)` はゾンビにも成功するので、そこだけ見ていると
    /// ssh 越しに殺された run の lease が永久に回収されない(2026-08-18 にリモートで実測)
    func testAZombieIsNotAlive() {
        XCTAssertFalse(RunHookLease.isAliveState(SZOMB))
        XCTAssertTrue(RunHookLease.isAliveState(SRUN))
        XCTAssertTrue(RunHookLease.isAliveState(SSLEEP))
        XCTAssertTrue(RunHookLease.isAliveState(SSTOP), "停止中(SIGSTOP)は生きている = 回収しない")
    }

    /// **exit 処理に入ったまま刺さったプロセスも死んだ扱い**。ゾンビになりきらずに残る形が
    /// 実在し(2026-08-18 にリモートで実測。ps の STAT が `?Es`)、生存扱いだと永久に回収されない
    func testAProcessStuckWhileExitingIsNotAlive() {
        let exiting: Int32 = 0x0000_2000  // <sys/proc.h> の P_WEXIT
        XCTAssertFalse(RunHookLease.isAliveState(SRUN, flags: exiting))
        XCTAssertFalse(RunHookLease.isAliveState(SSLEEP, flags: exiting))
        // 無関係なフラグは生存判定を変えない(P_WEXIT だけを見る)
        XCTAssertTrue(RunHookLease.isAliveState(SRUN, flags: 0x0000_0004))
    }
}
