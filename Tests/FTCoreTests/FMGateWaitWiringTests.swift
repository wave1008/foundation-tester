// FMGate → FMHealth.recordGateWait の**配線**の検証。
// gateWait の算術は FMHealthTests が見ている。ここが無いと「常に 0 を返す計測器」と
// 「待ちが無かった run」を区別できない —— 待ちが 0 なら直列化を緩める価値は無い、という
// 判断をこの数字1つに賭けるので、production の経路を実際に通ることを固定する。
//
// FMHealth.record は合成値(kind: "test")で直接叩くため、既定の書き込み先ではなく
// テストごとの一時ディレクトリへ逃がす(FT_FM_LIVENESS_DIR / FT_FM_USAGE_DIR。
// FMUsageLedgerTests / FMLivenessTests と同じ形)。逃がさないと本番の FM 台帳へ
// 「FM は生きている」という偽の観測を書いてしまう(実測 2026-09-08)

import FTTestSupport
import XCTest
@testable import FTCore

final class FMGateWaitWiringTests: XCTestCase {

    /// 待たせる時間。ロックのポーリング間隔(FMLock.acquire の 30ms)より十分に長くとる ——
    /// 短いと「保持中に2本目が入った」ことを再現できず、待ち 0 で通ってしまう
    private let holdSeconds: TimeInterval = 0.3

    private var livenessDir: URL!
    private var savedLivenessEnv: String?
    private var usageDir: URL!
    private var savedUsageEnv: String?
    /// **本番の枠に触らない**(FMLockTests と同じ理由): 枠のロックファイルは機械の全 fleetest
    /// プロセスと共有されるので、走っている run から枠を奪う/奪われると検証が負荷で揺れる
    private var lockDir: URL!

    override func setUpWithError() throws {
        lockDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMGateWaitWiringTests-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        FMLock.lockDirectoryForTesting = lockDir
        FMLock.resetForTesting()
        livenessDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMGateWaitWiringTests-liveness-\(UUID().uuidString)")
        savedLivenessEnv = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", livenessDir.path, 1)
        usageDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMGateWaitWiringTests-usage-\(UUID().uuidString)")
        savedUsageEnv = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"]
        setenv("FT_FM_USAGE_DIR", usageDir.path, 1)
        FMLiveness.resetWriteMemo()
    }

    override func tearDownWithError() throws {
        if let savedLivenessEnv { setenv("FT_FM_LIVENESS_DIR", savedLivenessEnv, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") }
        if let savedUsageEnv { setenv("FT_FM_USAGE_DIR", savedUsageEnv, 1) } else { unsetenv("FT_FM_USAGE_DIR") }
        FMLiveness.resetWriteMemo()
        try? FileManager.default.removeItem(at: livenessDir)
        try? FileManager.default.removeItem(at: usageDir)
        FMGate.leave()
        FMLock.concurrencyForTesting = nil
        FMLock.lockDirectoryForTesting = nil
        FMLock.resetForTesting()
        if let lockDir { try? FileManager.default.removeItem(at: lockDir) }
    }

    /// 1本目が門を保持している間に入った2本目は、**保持時間ぶんの待ちを記録する**。
    /// 枠を1に絞る —— 既定の並列枠(5)のままだと2本目が別の空き枠へ即座に入り、
    /// 待ちが発生せずこの検証が意味を失う
    func testGateRecordsWaitWhileAnotherHoldsIt() async throws {
        if !FMLock.isEnabled { throw XCTSkip("FT_FM_SERIALIZE=0 では待ちが発生しない") }
        // FMLock はホスト単位のファイル、FMBreaker もホスト単位の状態なので直列化する
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            FMBreaker.reset()   // 開いていると enter が短絡して門に触れない
            FMHealth.reset()

            let first = await FMGate.enter()
            XCTAssertTrue(first, "1本目は取れるはず")

            async let second = FMGate.enter()
            try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            FMGate.leave()
            let secondAcquired = await second
            XCTAssertTrue(secondAcquired, "解放後に2本目が取れるはず")
            FMGate.leave()

            // usage() は FM 呼び出しが1件も無ければ nil を返す契約なので、読むために1件入れる
            FMHealth.record(kind: "test", path: .text, ms: 1, ok: true)
            let usage = try XCTUnwrap(FMHealth.usage())
            XCTAssertGreaterThan(usage.gateWaitMaxMs, 200,
                                 "保持中に待った 300ms 前後が記録されるはず(0 なら配線が死んでいる)")
            XCTAssertGreaterThan(usage.gateWaitTotalMs, 200)
        }
    }

    /// 誰も保持していなければ待ちはほぼ 0(「常に待ちを盛る」変異を落とす)
    func testGateRecordsNearZeroWaitWhenUncontended() async throws {
        try await SharedResource.hostCaches.locked {
            FMBreaker.reset()
            FMHealth.reset()

            let acquired = await FMGate.enter()
            XCTAssertTrue(acquired)
            FMGate.leave()

            FMHealth.record(kind: "test", path: .text, ms: 1, ok: true)
            let usage = try XCTUnwrap(FMHealth.usage())
            XCTAssertLessThan(usage.gateWaitMaxMs, 100, "競合が無ければ待たない")
        }
    }
}
