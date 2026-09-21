// 機械の占有判定(docs/remote-runner.md §18.7 M2)。**ssh を足さずにその機械のディスクだけで
// 読む**契約なので、ここで固定するのは「ロックの中身 → 占有状態」の写像だけ。
// **手元も対象**(dispatch.lock は機械に1本で、ローカル run も同じ1本を取る)。

import XCTest
@testable import FTCore
import FTRemote

final class HostOccupancyTests: XCTestCase {

    private func info(issuer: String?, host: String = "dev-mbp", pid: Int32 = 42) -> String {
        RemoteDispatchLock.encode(RemoteDispatchLockInfo(
            issuerHost: host, pid: pid, acquiredAt: "2026-08-31T01:02:03Z", issuer: issuer)) ?? "{}"
    }

    func testNoLockDirectoryIsFree() {
        let state = HostOccupancy.interpret(lockDirExists: false, infoJSON: nil, myIssuer: "alice")
        XCTAssertFalse(state.held)
        XCTAssertNil(state.issuer)
        XCTAssertFalse(state.mine)
    }

    /// **info が読めなくても held は保つ**(「情報が読めなくてもロックは尊重する」の既存規則と
    /// 同じ向き)。ここを free に倒すと、壊れた info.json ひとつで配信の退避も占有表示も消える
    func testUnreadableInfoStaysHeldWithUnknownHolder() {
        for json in [nil, "", "{not json"] {
            let state = HostOccupancy.interpret(lockDirExists: true, infoJSON: json, myIssuer: "alice")
            XCTAssertTrue(state.held, "json=\(String(describing: json))")
            XCTAssertNil(state.issuer)
            XCTAssertFalse(state.mine, "保持者不明を自分扱いにしない")
        }
    }

    func testHolderFieldsAreCarriedThrough() {
        let state = HostOccupancy.interpret(
            lockDirExists: true, infoJSON: info(issuer: "bob"), myIssuer: "alice")
        XCTAssertTrue(state.held)
        XCTAssertEqual(state.issuer, "bob")
        XCTAssertEqual(state.issuerHost, "dev-mbp")
        XCTAssertEqual(state.acquiredAt, "2026-08-31T01:02:03Z")
        XCTAssertFalse(state.mine)
    }

    func testOwnLockIsMine() {
        let state = HostOccupancy.interpret(
            lockDirExists: true, infoJSON: info(issuer: "alice"), myIssuer: "alice")
        XCTAssertTrue(state.held)
        XCTAssertTrue(state.mine)
    }

    /// 旧 info.json(issuer キーが無い)。**mine=false に倒す** —— 自分のものと決めつけると、
    /// 破壊的操作の確認が「他人の run が走っている」と言わなくなる
    func testLegacyInfoWithoutIssuerIsNotMine() {
        let state = HostOccupancy.interpret(
            lockDirExists: true, infoJSON: info(issuer: nil), myIssuer: "alice")
        XCTAssertTrue(state.held)
        XCTAssertNil(state.issuer)
        XCTAssertFalse(state.mine)
    }

    /// **手元(FT_RUNNER_BASE 未設定)でも読む**(2026-09-21)—— dispatch.lock は機械に1本で、
    /// リモートへのディスパッチもローカル run も同じ1本を取る。ここを「ランナー機の文脈か」で
    /// 黙らせていた頃は、手元の run 中に錠前が出ず配信の退避も効かなかった。
    /// **環境変数を1つも読まない**ことまで固定する(引数から runnerBase が消えている)
    func testReadSeesTheLockOnTheLocalMachineToo() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-occupancy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // FT_RUNNER_BASE が立っていない状態でも「空き」を答える(黙らない = 拡張が
        // 「不明」と「空き」を区別できる)
        XCTAssertNil(RunnerBase.fromEnvironment([:]))
        XCTAssertEqual(HostOccupancy.read(myIssuer: "alice", home: home), .free)

        let lockDir = URL(fileURLWithPath: RemoteDispatchLock.lockDirPath(home: home.path))
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try info(issuer: "bob").write(
            toFile: RemoteDispatchLock.infoFilePath(home: home.path), atomically: true, encoding: .utf8)

        let state = HostOccupancy.read(myIssuer: "alice", home: home)
        XCTAssertEqual(state.held, true)
        XCTAssertEqual(state.issuer, "bob")
        XCTAssertFalse(state.mine)

        // 自分のロックなら mine(拡張の「ライブ更新」ON はこの行だけ畳まない)
        XCTAssertTrue(HostOccupancy.read(myIssuer: "bob", home: home).mine)
    }

    // MARK: - RemoteDestructiveGuard(占有中のホストでデバイスを止めない)

    func testGuardProceedsWhenTheLockIsAbsent() {
        XCTAssertEqual(RemoteDestructiveGuard.decide(probe: .absent, ignoreLock: false), .proceed)
    }

    /// **読めないときは通す** —— 掃除が永久にできなくなるほうが害が大きい(ロック照会は助言)
    func testGuardProceedsWhenTheLockCannotBeProbed() {
        XCTAssertEqual(RemoteDestructiveGuard.decide(probe: nil, ignoreLock: false), .proceed)
    }

    /// **保持者が誰かによらず止める**(自分の run でも殺されることに変わりはない)
    func testGuardRefusesWhileAnyDispatchHoldsTheLock() {
        let held = RemoteDispatchLock.Probe.held(RemoteDispatchLockInfo(
            issuerHost: "dev-mbp", pid: 7, acquiredAt: "2026-08-31T00:00:00Z", issuer: "bob"))
        guard case .refuse(let reason) = RemoteDestructiveGuard.decide(probe: held, ignoreLock: false) else {
            return XCTFail("expected refuse")
        }
        XCTAssertTrue(reason.contains("bob"), reason)
        XCTAssertTrue(reason.contains("--ignore-lock"), reason)

        guard case .refuse = RemoteDestructiveGuard.decide(
            probe: .held(nil), ignoreLock: false) else {
            return XCTFail("保持者不明でも止める")
        }
    }

    func testGuardWarnsInsteadOfRefusingWithIgnoreLock() {
        let held = RemoteDispatchLock.Probe.held(RemoteDispatchLockInfo(
            issuerHost: "dev-mbp", pid: 7, acquiredAt: "2026-08-31T00:00:00Z", issuer: "bob"))
        guard case .proceedWithWarning(let message) = RemoteDestructiveGuard.decide(
            probe: held, ignoreLock: true) else {
            return XCTFail("expected proceedWithWarning")
        }
        XCTAssertTrue(message.contains("bob"), message)
    }

    /// **役割は StreamLease の置き場だけ**(dispatch.lock / dispatch.queue の場所も、
    /// 占有を配るかどうかも、ここからは導かない)
    func testRunnerBaseReadsTheEnvironmentKey() {
        XCTAssertEqual(RunnerBase.fromEnvironment(["FT_RUNNER_BASE": "/Users/ci/fleetest-runner"]),
                       "/Users/ci/fleetest-runner")
        XCTAssertNil(RunnerBase.fromEnvironment(["FT_RUNNER_BASE": ""]))
        XCTAssertNil(RunnerBase.fromEnvironment([:]))
    }
}
