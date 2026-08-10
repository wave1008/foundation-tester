// **回す本数を超える台数を用意しない**(ResolvedProfile.deviceKeepCount)。
//
// 1本のシナリオでもプロファイルの全台にブリッジを供給しアプリの版を確認していたため、
// 実測で iOS の固定費が 14.8s(合計 21.8s のうちテスト実行は 7.0s)あった。絞ると 2.9s。
// 守るのは両方向 —— **絞りすぎ**(全件実行で並列度が死ぬ)と**予備なし**(用意した台が
// blank/frozen で弾かれると run ごと落ちる)の両方を落とす。

import XCTest
@testable import FTCore

final class ResolvedProfileDeviceLimitTests: XCTestCase {

    /// 1本なら「1本 + 予備1台」
    func testOneScenarioKeepsTwoDevices() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 10, scenarios: 1), 2)
    }

    /// **予備を必ず1台残す**(用意した台が弾かれても run が続く)
    func testKeepsOneSpareBeyondTheScenarioCount() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 10, scenarios: 3), 4)
    }

    /// **絞りすぎない**: 本数が台数以上なら全台(全件実行で並列度を落とさない)
    func testManyScenariosKeepEveryDevice() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 4, scenarios: 50), 4)
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 4, scenarios: 4), 4)
    }

    /// 本数が分からない(0)なら絞らない。platform 不一致で 0 になる経路がある
    func testZeroScenariosDoesNotLimit() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 8, scenarios: 0), 8)
    }

    /// 台数より多く要求しても台数を超えない
    func testNeverExceedsAvailable() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 2, scenarios: 1), 2)
    }
}
