// CoreSimulator 直叩き(FTCoreSimShim)と simctl 経路の等価性検証。
// 実マシンの CoreSimulator/simctl に触れるため FT_LIVE_SIM=1 のときのみ実行(CI では走らない)。

import XCTest
@testable import FTBridgeClient

final class SimulatorCatalogCoreSimTests: XCTestCase {

    func testCoreSimMatchesSimctl() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_SIM"] == "1",
                          "FT_LIVE_SIM=1 のときのみ")
        guard let viaShim = SimulatorCatalog.devicesViaCoreSimulator() else {
            throw XCTSkip("CoreSimulator シム利用不能(この環境では simctl フォールバックのみ)")
        }
        let viaSimctl = try SimulatorCatalog.devicesViaSimctl()
        // 列挙の合間に boot/shutdown が起きない前提の完全一致(ソート契約込み)
        XCTAssertEqual(viaShim, viaSimctl)
        XCTAssertFalse(viaShim.isEmpty)
    }

    /// 2回目以降の列挙が simctl より速いこと(初回は dlopen+ctx 初期化を含むため除外)
    func testCoreSimIsFasterThanSimctl() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_SIM"] == "1",
                          "FT_LIVE_SIM=1 のときのみ")
        guard SimulatorCatalog.devicesViaCoreSimulator() != nil else {
            throw XCTSkip("CoreSimulator シム利用不能")
        }
        let t0 = Date()
        _ = SimulatorCatalog.devicesViaCoreSimulator()
        let shimSec = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = try SimulatorCatalog.devicesViaSimctl()
        let simctlSec = Date().timeIntervalSince(t1)
        XCTAssertLessThan(shimSec, simctlSec,
                          "shim \(shimSec * 1000)ms >= simctl \(simctlSec * 1000)ms")
    }
}
