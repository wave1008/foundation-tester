import XCTest

@testable import FTBridgeClient

/// 供給ロック(ProvisionLock)を**ポート確保まで**に短縮するための2部品を固定する。
///
/// 実測 2026-08-30: ワーカーが2つあるのに iOS 5 本の供給 95 秒がすべて直列だった。
/// provision() が ready 待ち(1本 7〜28 秒)までロックを握っていたため。関門が壊れると
/// ①合図が足りなければロックが**永久に解放されない**(他プロセスの供給が止まる)
/// ②多すぎれば採番中に解放され、別プロセスと同じ空きポートを取り合う(bindFailed 48)。
final class PortClaimBarrierTests: XCTestCase {

    /// 全ブリッジが確保を報告した時点で待ちが解ける
    func testWaitAllResumesOnceEveryBridgeHasClaimed() async {
        let barrier = PortClaimBarrier(expected: 3)
        let waiter = Task { await barrier.waitAll() }
        for _ in 0..<3 { await barrier.claimed() }
        await waiter.value  // 解けなければここでハングする(タイムアウトで検出)
    }

    /// 0 本(供給するブリッジが無い)ならすぐ解ける
    func testWaitAllReturnsImmediatelyWhenNothingToClaim() async {
        await PortClaimBarrier(expected: 0).waitAll()
    }

    /// **余分な合図で早く解けない**。撃ち過ぎても remaining は 0 で止まる
    func testExtraClaimsDoNotUnderflow() async {
        let barrier = PortClaimBarrier(expected: 1)
        await barrier.claimed()
        await barrier.claimed()
        await barrier.waitAll()
    }

    /// ClaimOnce は同じブリッジから何度撃たれても関門を**1つしか**進めない。
    /// executeBridge の各経路と executeDevice の保険で二重に撃つ作りなので、ここが緩むと
    /// 1 本ぶんの合図で関門が満たされ、**まだ採番中の別ブリッジがある間にロックが解ける**
    /// (= 他プロセスと同じ空きポートを取り合う)。
    /// **別インスタンスを 2 つ撃つ形では検出できない** —— 同じ 1 つを撃ち続けて確かめる
    func testClaimOnceCountsOnlyOncePerBridgeEvenWhenFiredRepeatedly() async {
        actor Flag {
            private var value = false
            func set() { value = true }
            func get() -> Bool { value }
        }
        let barrier = PortClaimBarrier(expected: 2)
        let flag = Flag()
        let waiter = Task { await barrier.waitAll(); await flag.set() }

        let only = ClaimOnce(barrier: barrier)
        for _ in 0..<5 { await only.fire() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let resolvedEarly = await flag.get()
        XCTAssertFalse(resolvedEarly,
                       "同じブリッジの合図を二重計上している(1 本だけで関門が満たされた)")

        await ClaimOnce(barrier: barrier).fire()  // 2 本目
        await waiter.value
    }

    // MARK: - 配線(純関数では届かない呼び出し側)

    /// **ポート確保の直後に合図を撃つ**こと。startDetached が pid ファイルを書いた時点が
    /// 「確保済み」で、そこで撃たないとロックが ready 待ちまで握られたまま = 最適化が消える。
    /// 撃つ位置がずれても型検査は通るのでソースで縛る
    func testTheClaimIsSignalledRightAfterTheRunnerIsStarted() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "try launcher.startDetached()"))
        let following = String(code[start.upperBound...].prefix(120))
        XCTAssertTrue(following.contains("await claimed()"),
                      "startDetached の直後に await claimed() が無い"
                      + "(ロックが ready 待ちまで握られたままになる)")
    }

    /// **1本ぶんの合図が欠けたら解けない**(= 上のテストが「常に解ける」実装を通してしまわない
    /// ことの陰性対照)。待ちタスクの完了を旗で観測する —— `task.value` を子タスクで待つ形にすると
    /// キャンセルが効かず、テスト自体が終わらなくなる
    func testWaitAllStaysBlockedWhileAClaimIsMissing() async {
        actor Flag {
            private var value = false
            func set() { value = true }
            func get() -> Bool { value }
        }
        let barrier = PortClaimBarrier(expected: 2)
        let flag = Flag()
        let waiter = Task { await barrier.waitAll(); await flag.set() }
        await ClaimOnce(barrier: barrier).fire()  // 2 本中 1 本だけ

        try? await Task.sleep(nanoseconds: 200_000_000)
        let resolvedEarly = await flag.get()
        XCTAssertFalse(resolvedEarly, "合図が1本足りないのに待ちが解けている")

        await ClaimOnce(barrier: barrier).fire()  // 残り1本
        await waiter.value
        let resolved = await flag.get()
        XCTAssertTrue(resolved, "全部の合図が揃ったのに待ちが解けない")
    }

    /// ProvisionLock.release() は冪等 —— 早期解放と末尾の defer の両方から呼ばれる。
    /// **危険は「2 回目が通ること」ではなく「2 回目の close(fd) が無関係な fd を閉じること」**
    /// (fd は最小の空き番号が再利用される)。解放後に別のファイルを開き、それが生きたままで
    /// あることまで見る —— ここを緩めると「2 回呼んでも落ちない」だけのテストになる
    func testProvisionLockReleaseDoesNotCloseAnUnrelatedDescriptor() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try ProvisionLock(stateDir: dir)
        lock.release()

        // 解放で空いた fd 番号をこのファイルが拾う
        let probe = open(dir.appendingPathComponent("probe").path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(probe, 0, "前提: 検査用のファイルを開けること")
        defer { close(probe) }

        lock.release()  // 2 回目
        XCTAssertNotEqual(fcntl(probe, F_GETFD), -1,
                          "2 回目の release が無関係な fd を閉じた(release が冪等でない)")
    }
}
