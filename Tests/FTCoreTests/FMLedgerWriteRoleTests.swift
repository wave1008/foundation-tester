// FMLedgerWriteRole(FM 台帳の書き込み許可)の検証。
//
// 元の門は「XCTestConfigurationFilePath が無ければ書く」(fail-open)で、`swift test --parallel`
// のワーカーではこの環境変数が立たないことがあり、合成値の FMHealth.record が本番の台帳を
// 汚した(実測 2026-09-08)。ここは向きを反転した新しい門(fail-closed: opt-in が無ければ
// 書かない)を、`XCTestConfigurationFilePath` の有無に依存しない形で直接検証する
// (env を消して検証すると実行環境 —— --parallel かどうか等 —— に結果が左右される)。

import FTTestSupport
import XCTest
@testable import FTCore

final class FMLedgerWriteRoleTests: XCTestCase {

    override func tearDown() {
        FMLedgerWriteRole.resetForTesting()
        super.tearDown()
    }

    /// opt-in していないプロセスは許可されない。呼び出し忘れの既定値がこちらであることを固定する
    /// (`isProduction` の既定を true に変える変異はここで落ちる)
    func testDisabledUntilProductionOptsIn() {
        FMLedgerWriteRole.resetForTesting()
        XCTAssertFalse(FMLedgerWriteRole.permitsProductionWrite)
    }

    /// `enableForProduction()` を呼んだら許可される(no-op 化する変異はここで落ちる)
    func testEnableForProductionGrantsPermission() {
        FMLedgerWriteRole.resetForTesting()
        FMLedgerWriteRole.enableForProduction()
        XCTAssertTrue(FMLedgerWriteRole.permitsProductionWrite)
    }

    /// FMLiveness / FMUsageLedger の書き込み先そのものがこの門を読んでいることを固定する。
    /// **`FT_FM_LIVENESS_DIR` / `FT_FM_USAGE_DIR` の明示オーバーライドが無い状態**で確かめる ——
    /// オーバーライドは門より先に効くので、それが無いことでこの門を実際に踏ませる。
    /// env の書き換えはこのテスト自身の一時ディレクトリ隔離のためだけで、
    /// `XCTestConfigurationFilePath` には一切触れない
    func testFMLivenessWriteURLIsNilWithoutOptIn() throws {
        try SharedResource.hostCaches.locked {
            let savedLiveness = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
            unsetenv("FT_FM_LIVENESS_DIR")
            defer {
                if let savedLiveness { setenv("FT_FM_LIVENESS_DIR", savedLiveness, 1) }
            }
            FMLedgerWriteRole.resetForTesting()
            XCTAssertNil(FMLiveness.writeURL,
                        "opt-in の無いプロセスから本番の fm-liveness.json への書き込み先が開いている")
        }
    }

    func testFMUsageLedgerWriteDirectoryIsNilWithoutOptIn() throws {
        try SharedResource.hostCaches.locked {
            let savedUsage = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"]
            unsetenv("FT_FM_USAGE_DIR")
            defer {
                if let savedUsage { setenv("FT_FM_USAGE_DIR", savedUsage, 1) }
            }
            FMLedgerWriteRole.resetForTesting()
            XCTAssertNil(FMUsageLedger.writeDirectory,
                        "opt-in の無いプロセスから本番の fm-usage/ への書き込み先が開いている")
        }
    }

    /// **ブレーカの置き場も同じ門を通る**。合成値の `FMHealth.record(ok: false)` を叩くテスト
    /// (FMHealthTests)が本番のブレーカを落とすと、**この機械の FM が 10 分止まる**
    /// (実害2件・2026-09-08: 耐久 run が FM 無しで走った / 同じスイートの FMGateWaitWiringTests が
    /// `FMGate.enter` を短絡されて落ちた)。判定は I/O 抜きで置き場の決まり方だけを見る ——
    /// 本番ファイルの有無で見ると、並列の別プロセスや同時に動く production の run と競合する
    func testBreakerStateIsProcessLocalWithoutOptIn() {
        let saved = FMBreaker.stateURLForTesting
        FMBreaker.stateURLForTesting = nil
        defer { FMBreaker.stateURLForTesting = saved }

        FMLedgerWriteRole.resetForTesting()
        XCTAssertNotEqual(FMBreaker.stateURL, FMBreaker.defaultStateURL,
                          "opt-in の無いプロセスが本番のブレーカを掴んでいる")
        XCTAssertTrue(FMBreaker.stateURL.lastPathComponent.contains("\(getpid())"),
                      "プロセスごとに隔離されていない(別のテストプロセスと共有される)")

        FMLedgerWriteRole.enableForProduction()
        XCTAssertEqual(FMBreaker.stateURL, FMBreaker.defaultStateURL,
                       "production では従来どおりホスト単位で1つ(ワーカー間で落ちた事実を共有する)")
    }

    /// 差し替え口は門より強い(ブレーカ自体を検証するテストが従来どおり動く)
    func testBreakerTestingOverrideWinsOverTheRole() {
        let saved = FMBreaker.stateURLForTesting
        let override = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-breaker-role-test.state")
        FMBreaker.stateURLForTesting = override
        defer { FMBreaker.stateURLForTesting = saved }

        FMLedgerWriteRole.resetForTesting()
        XCTAssertEqual(FMBreaker.stateURL, override)
        FMLedgerWriteRole.enableForProduction()
        XCTAssertEqual(FMBreaker.stateURL, override)
    }
}
