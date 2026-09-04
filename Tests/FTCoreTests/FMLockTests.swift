// FMLock(FM 呼び出しのホスト単位の許可枠)の検証。
// ここが壊れると FM が枠数を超えて並列に投げられ、modelmanagerd のモデル積み降ろしが増える
// (枠1本なら、想定より多く並列に取れてしまう。枠 N 本なら N+1 本目が取れてしまう)。

import FTTestSupport
import XCTest
@testable import FTCore

final class FMLockTests: XCTestCase {

    /// 殺しスイッチが立っているときは排他しないのが正しい挙動なので、排他の検証は飛ばす
    private func requireSerializationEnabled() throws {
        if !FMLock.isEnabled { throw XCTSkip("FT_FM_SERIALIZE=0 では排他しない") }
    }

    override func tearDown() {
        // テストが途中で落ちても枠を残さない。concurrencyForTesting を使ったテストが
        // 何本掴んでいたか分からないので、余分に release() する(無害。何も持っていなければ no-op)
        for _ in 0..<20 { FMLock.release() }
        FMLock.concurrencyForTesting = nil
        FMLock.resetForTesting()
        super.tearDown()
    }

    /// 保持中は同一プロセスの別要求が取れない(flock は同じ fd では素通りするため、
    /// プロセス内の排他が別に要る = この検証が無いと直列化が効かない)。枠1で確認
    func testSecondAcquireFailsWhileHeldAtConcurrencyOne() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            let acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
            let second = await FMLock.acquire(timeoutSeconds: 0.3)
            XCTAssertFalse(second, "枠1本を保持中は取れないはず")
        }
    }

    /// **枠の数だけ同時に取れる**。N+1 本目は取れない
    func testExactlyConcurrencySlotsAreAcquirable() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 3
            FMLock.resetForTesting()
            for i in 0..<3 {
                let acquired = await FMLock.acquire(timeoutSeconds: 1)
                XCTAssertTrue(acquired, "\(i)本目は枠内なので取れるはず")
            }
            let overLimit = await FMLock.acquire(timeoutSeconds: 0.3)
            XCTAssertFalse(overLimit, "枠3本を使い切ったら4本目は取れないはず")
        }
    }

    /// 1本返すと次が取れる
    func testAcquireSucceedsAfterRelease() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            var acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
            FMLock.release()
            acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
        }
    }

    /// 既定の枠数を**リテラルで固定する**。他のテストは concurrencyForTesting で枠数を明示するので、
    /// production の既定値を1度も通らない —— ここが無いと既定を1(直列化)へ戻す変更が緑のまま通り、
    /// 実測 204.8 秒のゲート待ちが黙って復活する(2026-09-01 実測。5 の根拠は FMLock.swift 冒頭)。
    /// **変えるときはこの数字と根拠を両方更新すること**
    func testDefaultConcurrencyIsPinned() throws {
        XCTAssertEqual(FMLock.defaultConcurrency, 5)
        // **`FMLock.concurrency` では確かめない**: あれは**この機械の設定ファイル**を読むので、
        // ホストが `fmConcurrency` を入れているだけで落ちる(実際に 1 を入れた機械で落ちた)。
        // 上書きが無いときに既定が効くことは、解決そのものの純関数で見る
        XCTAssertEqual(FMLock.resolveConcurrency(environment: [:], configured: nil), 5,
                       "上書きが無ければ既定が効く")
    }

    /// **返した枠が再利用される**。N 本取る → 1本返す → もう1本取れる、を繰り返しても枯れない
    func testReleasedSlotIsReusedRepeatedly() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 2
            FMLock.resetForTesting()
            for _ in 0..<2 {
                let acquired = await FMLock.acquire(timeoutSeconds: 1)
                XCTAssertTrue(acquired)
            }
            let exhausted = await FMLock.acquire(timeoutSeconds: 0.3)
            XCTAssertFalse(exhausted, "2本使い切った直後は取れない")

            for cycle in 0..<5 {
                FMLock.release()
                let reused = await FMLock.acquire(timeoutSeconds: 1)
                XCTAssertTrue(reused, "cycle \(cycle): 返した枠が再利用できるはず")
                let stillCapped = await FMLock.acquire(timeoutSeconds: 0.3)
                XCTAssertFalse(stillCapped, "cycle \(cycle): 依然として2本で頭打ちのはず")
            }
        }
    }

    /// timeout はおおむね守る(待ち続けてシナリオのタイムアウトを食い潰さない)
    func testAcquireRespectsTimeout() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            let acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
            let started = Date()
            _ = await FMLock.acquire(timeoutSeconds: 0.5)
            let waited = Date().timeIntervalSince(started)
            XCTAssertLessThan(waited, 2.0, "timeout を大きく超えて待ってはいけない")
            XCTAssertGreaterThan(waited, 0.3, "timeout より極端に早く諦めてもいけない")
        }
    }

    /// 二重 release は無害(defer と早期 return が重なっても壊れない)
    func testDoubleReleaseIsHarmless() async throws {
        try requireSerializationEnabled()
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            var acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
            FMLock.release()
            FMLock.release()
            acquired = await FMLock.acquire(timeoutSeconds: 1)
            XCTAssertTrue(acquired)
        }
    }

    /// 殺しスイッチ(A/B 計測用)。無効時は常に取れる = 素通り
    func testKillSwitchMakesAcquireAlwaysSucceed() async throws {
        guard ProcessInfo.processInfo.environment["FT_FM_SERIALIZE"] == "0" else {
            throw XCTSkip("FT_FM_SERIALIZE=0 のときだけ意味を持つ検証")
        }
        try await SharedResource.hostCaches.locked {
            FMLock.concurrencyForTesting = 1
            FMLock.resetForTesting()
            var acquired = await FMLock.acquire(timeoutSeconds: 0.1)
            XCTAssertTrue(acquired)
            acquired = await FMLock.acquire(timeoutSeconds: 0.1)
            XCTAssertTrue(acquired, "無効時は保持中でも素通りする")
        }
    }

    /// FT_FM_CONCURRENCY の不正値(0・負・数字でない)は既定へ倒れる
    func testInvalidConcurrencyEnvFallsBackToDefault() throws {
        try SharedResource.hostCaches.locked {
            let saved = ProcessInfo.processInfo.environment["FT_FM_CONCURRENCY"]
            defer {
                if let saved { setenv("FT_FM_CONCURRENCY", saved, 1) } else { unsetenv("FT_FM_CONCURRENCY") }
            }
            // **不正値の行き先は純関数で見る**: `FMLock.concurrency` の落とし先は設定ファイル →
            // 既定の順で、設定を入れている機械では既定に届かない(それは仕様どおりの挙動)
            for invalid in ["0", "-1", "not-a-number", ""] {
                XCTAssertEqual(
                    FMLock.resolveConcurrency(environment: ["FT_FM_CONCURRENCY": invalid],
                                              configured: nil), 5,
                    "FT_FM_CONCURRENCY=\(invalid) は既定(5)へ倒れるはず")
            }
            setenv("FT_FM_CONCURRENCY", "7", 1)
            XCTAssertEqual(FMLock.concurrency, 7, "正の整数は素通しするはず")
        }
    }
}

/// 枠数の解決(環境変数 → 設定ファイル → 既定)。**GUI が書くのは設定ファイル経路**なので、
/// ここが通らないと「設定タブで入れた値が効かない」が緑のまま通る。
/// `FMLock.concurrency` はホストの実ファイルを読むため、純粋関数の側で検証する。
final class FMLockConcurrencyResolutionTests: XCTestCase {
    func testEnvironmentWinsOverConfigFile() {
        XCTAssertEqual(
            FMLock.resolveConcurrency(environment: ["FT_FM_CONCURRENCY": "2"], configured: 7), 2)
    }

    func testConfigFileIsUsedWhenNoEnvironment() {
        XCTAssertEqual(FMLock.resolveConcurrency(environment: [:], configured: 3), 3)
    }

    /// 既定(5)と違う値で確かめる —— 既定と同じ値で書くと「設定を読んでいない実装」でも通る
    func testConfigFileValueIsNotTheDefault() {
        XCTAssertNotEqual(3, FMLock.defaultConcurrency, "既定と同じ値では検証にならない")
    }

    func testFallsBackToDefaultWithoutAnySource() {
        XCTAssertEqual(FMLock.resolveConcurrency(environment: [:], configured: nil),
                       FMLock.defaultConcurrency)
    }

    /// 0 と負値は「未設定」= 既定へ倒す(GUI は空欄を 0 として送る)
    func testNonPositiveConfigFallsBackToDefault() {
        XCTAssertEqual(FMLock.resolveConcurrency(environment: [:], configured: 0),
                       FMLock.defaultConcurrency)
        XCTAssertEqual(FMLock.resolveConcurrency(environment: [:], configured: -1),
                       FMLock.defaultConcurrency)
    }

    /// **不正な環境変数は設定ファイルへ落ちる**(既定へ直行しない)。リモートのディスパッチが
    /// 壊れた値を運んでも、ランナー自身の設定が生きる
    func testInvalidEnvironmentFallsThroughToConfigFile() {
        XCTAssertEqual(
            FMLock.resolveConcurrency(environment: ["FT_FM_CONCURRENCY": "abc"], configured: 4), 4)
        XCTAssertEqual(
            FMLock.resolveConcurrency(environment: ["FT_FM_CONCURRENCY": "0"], configured: 4), 4)
    }
}
