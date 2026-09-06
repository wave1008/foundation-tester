// LAN bind のブリッジがトークンを実際に要求していることの配線チェック(ソース走査)。
//
// なぜ走査なのか: 判定(BridgeAPI.bridgeTokenMatches / bridgeTokenRequired)は
// BridgeTokenTests が本物の関数で固めているが、**それを呼んでいるのは
// Runner/FleetestRunnerUITests/BridgeHTTPServer.swift** で、Runner ターゲットは
// swift test がビルドしない。つまり照合を丸ごと消しても全テストが緑のまま通る。
// 同型: OverlayWindowOcclusionWiringTests(配線)・ProcessLivenessSourceScanTests(禁止形)。
//
// 失敗の形が沈黙(認証なしで LAN に開いたまま緑)なので、粗くてもここで止める価値がある。

import XCTest
import FTCore

final class BridgeTokenWiringTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private func bridgeServerSource() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(
            "Runner/FleetestRunnerUITests/BridgeHTTPServer.swift"), encoding: .utf8)
    }

    /// bindAll のまま起動を許してはいけない(fail closed)。throw を消す変異をここで落とす
    func testServerRefusesToStartWhenBoundToAllInterfacesWithoutAToken() throws {
        let source = try bridgeServerSource()
        XCTAssertTrue(source.contains("bridgeTokenRequired(bindAll:"),
                      "start() が BridgeAPI.bridgeTokenRequired を通っていない")
        XCTAssertTrue(source.contains("throw ServerError.tokenMissing"),
                      "トークン不在で起動を止める throw が無い(fail closed が外れている)")
    }

    /// 照合は accept ループで、**XCUITest を触る前に**行う。`dispatchToMain` より後ろへ移すと
    /// 未認証の要求が実機を操作してから 401 になる
    func testAuthCheckRunsBeforeAnythingTouchesXCUITest() throws {
        let source = try bridgeServerSource()
        guard let matchIndex = source.range(of: "bridgeTokenMatches(expected:")?.lowerBound else {
            return XCTFail("acceptLoop が BridgeAPI.bridgeTokenMatches を呼んでいない")
        }
        guard let dispatchIndex = source.range(of: "writeResponse(clientFD, dispatchToMain(request))")?
            .lowerBound else {
            return XCTFail("acceptLoop の dispatchToMain 呼び出しが見つからない(走査の前提が崩れた)")
        }
        XCTAssertLessThan(matchIndex, dispatchIndex,
                          "照合が dispatchToMain より後ろにある(未認証の要求がデバイスに届く)")
        XCTAssertTrue(source.contains("status: 401"), "拒否が 401 で返っていない")
    }

    /// 手書きの比較へ戻す変異(タイミングで手掛かりを与える)を落とす。
    /// **`==` と `!=` の両方を禁じる** —— 片方だけ見ると否定形の書き換えを素通しする
    func testAuthUsesTheSharedConstantTimeComparison() throws {
        let source = try bridgeServerSource()
        for forbidden in ["== expectedToken", "expectedToken ==",
                          "!= expectedToken", "expectedToken !="] {
            XCTAssertFalse(source.contains(forbidden),
                           "素の \(forbidden) で照合している(BridgeAPI.bridgeTokenMatches を使うこと)")
        }
    }

    /// ランナーは LAN アドレスを標準出力へ告知する(ホストがログから拾う)。**そこにトークンを
    /// 混ぜない** —— .fleetest/bridge-<port>.log は共有ランナー機で誰でも読める
    func testTheAnnouncedAddressLineCarriesNoToken() throws {
        let source = try bridgeServerSource()
        guard let line = source.split(separator: "\n")
            .first(where: { $0.contains("FT_BRIDGE_ADDR=") && $0.contains("print(") }) else {
            return XCTFail("announceAddress の告知行が見つからない(走査の前提が崩れた)")
        }
        XCTAssertFalse(line.contains("oken"), "告知行にトークンが載っている: \(line)")
    }
}
