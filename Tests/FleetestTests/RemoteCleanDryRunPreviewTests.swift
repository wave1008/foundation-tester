// `remote clean --dry-run` のプレビュー行(RemoteCommand.Clean.devicesPreviewLines)。
//
// 実測(2026-09-16 05:54): ランナーが run 中(dispatch.lock 保持)でも `--dry-run` は
// ロックを読まずに「→ would stop bridges and shut down simulators/emulators」を出し rc=0 で
// 終わっていた。本番(--dry-run 無し)は正しく「error: not cleaned: a dispatch is running on
// this host (…pid N…)」で rc=1 になるので、--dry-run で確かめてから本番を叩く案内と食い違う。
//
// ここで固定するのは「`RemoteDestructiveGuard.decide` の結果 → プレビュー文」の写像だけ
// (ssh は呼ばない。judge への入力は直接注入する)。実際にロックを読む配線
// (cleanOne が dry-run でも probeLock を呼ぶこと)は本ファイルの対象外 —— ssh が要るため
// ここでは検証できない。

import XCTest
import FTRemote
@testable import fleetest

final class RemoteCleanDryRunPreviewTests: XCTestCase {

    private func heldInfo(pid: Int32 = 4242) -> RemoteDispatchLockInfo {
        RemoteDispatchLockInfo(issuerHost: "runner-mbp", pid: pid, acquiredAt: "2026-09-16T05:50:00Z")
    }

    /// ロック無し(absent) → 従来どおりの予告
    func testNoLockPreviewsTheNormalStopMessage() {
        let decision = RemoteDestructiveGuard.decide(probe: .absent, ignoreLock: false)
        XCTAssertEqual(
            RemoteCommand.Clean.devicesPreviewLines(decision: decision),
            ["→ would stop bridges and shut down simulators/emulators (skipped: --dry-run)"])
    }

    /// ロックを読めない(ssh 失敗など。probe: nil)→ 読めないときは通す規律のまま、
    /// dry-run のプレビューも従来どおり(「掃除する」側を維持する)
    func testUnreadableLockPreviewsTheNormalStopMessage() {
        let decision = RemoteDestructiveGuard.decide(probe: nil, ignoreLock: false)
        XCTAssertEqual(
            RemoteCommand.Clean.devicesPreviewLines(decision: decision),
            ["→ would stop bridges and shut down simulators/emulators (skipped: --dry-run)"])
    }

    /// **本命**: ロック保持あり → 本番は掃除しないことを予告する(保持者 pid・開始時刻つき)。
    /// 実測のバグは、この分岐が dry-run では一度も通らなかったこと
    func testHeldLockPreviewsThatTheRealRunWouldRefuse() {
        let decision = RemoteDestructiveGuard.decide(probe: .held(heldInfo(pid: 4242)), ignoreLock: false)
        let lines = RemoteCommand.Clean.devicesPreviewLines(decision: decision)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let line = lines[0]
        XCTAssertTrue(line.contains("the real run would refuse to clean this host"), line)
        XCTAssertTrue(line.contains("pid 4242"), line)
        XCTAssertTrue(line.contains("(skipped: --dry-run)"), line)
    }

    /// 保持あり + --ignore-lock → 本番と同じ警告文を見せた上で、プレビューは続行する
    func testHeldLockWithIgnoreLockPreviewsTheWarningAndContinues() {
        let decision = RemoteDestructiveGuard.decide(probe: .held(heldInfo(pid: 99)), ignoreLock: true)
        let lines = RemoteCommand.Clean.devicesPreviewLines(decision: decision)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("warning: --ignore-lock:"), lines[0])
        XCTAssertEqual(lines[1], "→ would stop bridges and shut down simulators/emulators (skipped: --dry-run)")
    }

    // MARK: - 配線(dry-run でもロックを読むこと)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCleanOneProbesTheLockBeforeBranchingOnDryRun() throws {
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/fleetest/RemoteCommands.swift"),
            encoding: .utf8)
        guard let range = text.range(of: "private func cleanOne(_ raw: String) throws {") else {
            XCTFail("cleanOne not found")
            return
        }
        let body = text[range.upperBound...]
        guard let probeCallRange = body.range(of: "probeLock(target: target, layout: layout)"),
              let branchRange = body.range(of: "if RemoteCleanPlan.stopsDevices(dryRun: dryRun) {")
        else {
            XCTFail("expected probeLock(...) and the stopsDevices branch inside cleanOne")
            return
        }
        XCTAssertTrue(probeCallRange.lowerBound < branchRange.lowerBound,
                      "probeLock must run before the dryRun branch, not only inside the non-dry-run arm")
    }
}
