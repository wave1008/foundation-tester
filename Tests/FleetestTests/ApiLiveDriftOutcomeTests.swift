import XCTest
@testable import fleetest
import FTCore

/// ライブ操作(api live serve)の毎コマンドの本人確認(`HybridFallbackIdentity.drifted` の3値)から
/// 「差し替える/断る/何もしない」を決める純粋関数(`ApiLiveServe.liveDriftOutcome`)を、
/// 実ブリッジ無しで固定する。判定そのもの(`FTCore.BridgeIdentityCheck.hybridFallbackDrift`)は
/// Tests/FTCoreTests/BridgeIdentityCheckTests.swift が固定するので、ここで見るのは
/// 「その3値をライブ操作がどう扱うか」だけ。MCP 側の対の振り分け(`primaryEngineOutcome`)は
/// Tests/FleetestMCPTests/HybridFallbackDriftTests.swift。
final class ApiLiveDriftOutcomeTests: XCTestCase {

    func testUnchangedWhenNoDrift() {
        let outcome = ApiLiveServe.liveDriftOutcome(drift: .none, port: 8123, expectedUDID: "SIM-1")
        XCTAssertEqual(outcome, .unchanged)
    }

    /// 同じ台のブリッジがエンジンだけ入れ替わった形は、現状どおり差し替える(rebuild)
    func testRebuildsWhenTheSameDeviceChangedEngine() {
        let outcome = ApiLiveServe.liveDriftOutcome(
            drift: .sameDeviceEngineChanged, port: 8123, expectedUDID: "SIM-1")
        XCTAssertEqual(outcome, .rebuild)
    }

    /// **本題**: ポートの中身が別の台に替わったら、同じポートで作り直さず断る
    /// (黙って建て直すと別の台を触り続ける実害があった)
    func testRefusesWhenADifferentDeviceNowAnswers() {
        let outcome = ApiLiveServe.liveDriftOutcome(
            drift: .differentDevice, port: 8123, expectedUDID: "SIM-1")
        guard case .refuse(let message) = outcome else {
            return XCTFail("別の台に替わっていたら拒否のはず: \(outcome)")
        }
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("SIM-1"), message)
    }

    /// 拒否文は人間向け(拡張のライブ操作パネルを見ている人が読む)。MCP のエージェント向け文言
    /// (ft_list_devices 等)をそのまま流用しない
    func testDifferentDeviceMessageIsHumanReadable() {
        let message = ApiLiveServe.differentDeviceMessage(port: 8123, expectedUDID: "SIM-1")
        XCTAssertTrue(message.contains("port 8123"), message)
        XCTAssertTrue(message.contains("SIM-1"), message)
        XCTAssertFalse(message.contains("ft_"), "MCP 向けの文言(ft_* ツール名)を人間向けに出さない: \(message)")
    }

    /// 毎コマンド同じ材料を渡せば同じ判定になること(黙って片方の台に固定されない ——
    /// run() は driver/port/primaryEngine を書き換えずに次のコマンドへ進む)
    func testSameDriftAlwaysProducesTheSameOutcome() {
        let first = ApiLiveServe.liveDriftOutcome(drift: .differentDevice, port: 8123, expectedUDID: "SIM-1")
        let second = ApiLiveServe.liveDriftOutcome(drift: .differentDevice, port: 8123, expectedUDID: "SIM-1")
        XCTAssertEqual(first, second)
    }
}
