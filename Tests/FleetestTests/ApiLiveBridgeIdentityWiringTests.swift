import XCTest

/// api live serve が接続先を `--udid` 抜きで信用していた実地(L1): 既定ポートに居た
/// 別デバイスの生きたブリッジを掴んで操作を撃ち、版差を理由に止めて建て直した
/// (checkAndRestartIfStale)。判定(FTCore.BridgeIdentityCheck)自体は
/// Tests/FTCoreTests/BridgeIdentityCheckTests.swift が固定するので、ここは配線
/// (呼んでいるか・使う前に確かめているか)をソース走査で縛る。
///
/// **一段目の直しの穴**: 不一致を即 throw すると、`--port` を明示していない(=拡張が
/// ブリッジのまだ無い台を開く、まさに自動起動が想定する場面)ときに serve 自体が
/// 起動しなくなり、ライブ操作が開けなくなる。`driverOptions.port == nil` かどうかで
/// 断る/探す/自動起動へ回すを分けることを、ここで固定する。
final class ApiLiveBridgeIdentityWiringTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// makeLiveDriver は resolve が返した宛先を BridgeIdentityCheck で本人確認してから使う
    func testMakeLiveDriverVerifiesIdentityAfterResolving() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let resolveRange = code.range(of: "XCUIBridgeResolver.resolve(") else {
            return XCTFail("XCUIBridgeResolver.resolve が見当たらない")
        }
        guard let verifyRange = code.range(of: "Self.identityMismatch(") else {
            return XCTFail("BridgeIdentityCheck による本人確認(identityMismatch)を呼んでいない"
                + " — 別デバイスの生きたブリッジを黙って掴んで操作を撃つ(実地 L1)")
        }
        XCTAssertTrue(resolveRange.upperBound < verifyRange.lowerBound,
                      "本人確認は resolve の後で行うこと")
        XCTAssertTrue(code.contains("BridgeIdentityCheck.verdict("),
                      "判定は FTCore.BridgeIdentityCheck の1箇所を使うこと(二つ目の実装を書かない)")
        // **対処文は呼び手が持つ**(判定だけを共有する。run のレーンの文言をライブ操作に出さない)
        XCTAssertTrue(code.contains("remedy: \"Point --port at this device's bridge"),
                      "ライブ操作は自分の対処文を渡すこと(runLaneRemedy を流用しない)")
        XCTAssertFalse(code.contains("runLaneRemedy"),
                       "run のレーン向けの対処文をライブ操作で使わない")
    }

    /// **`--port` 明示時は断る**: 利用者が決めた宛先を勝手に変えない
    func testExplicitPortMismatchIsRefused() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let identityRange = code.range(of: "guard let mismatch = await Self.identityMismatch(")
        else {
            return XCTFail("identityMismatch の呼び出しが見当たらない")
        }
        guard let portGuardRange = code.range(
            of: "guard driverOptions.port == nil else {", range: identityRange.upperBound..<code.endIndex)
        else {
            return XCTFail("--port 明示かどうかの分岐(driverOptions.port == nil)が無い"
                + " — 明示された宛先と既定へのフォールバックを区別できていない")
        }
        let explicitBranch = String(code[portGuardRange.upperBound...].prefix(200))
        XCTAssertTrue(explicitBranch.contains("throw DriverError.bridgeIdentityMismatch(mismatch)"),
                      "--port 明示時は不一致を断ること(利用者の指定を勝手に変えない)")
    }

    /// **既定ポートへのフォールバック時は断らずに探す**: `BridgeDiscovery.scan` の結果から
    /// 要求 udid のポートを選ぶ配線があること
    func testFallbackPortMismatchSearchesInsteadOfRefusing() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let portGuardRange = code.range(of: "guard driverOptions.port == nil else {") else {
            return XCTFail("--port 明示かどうかの分岐が無い")
        }
        guard let scanRange = code.range(
            of: "BridgeDiscovery.scan(excluding:", range: portGuardRange.upperBound..<code.endIndex)
        else {
            return XCTFail("既定ポートへのフォールバック時に BridgeDiscovery.scan で"
                + " その udid のポートを探していない"
                + " — 見つかるはずの台でも serve が起動できず、ライブ操作が開けなくなる")
        }
        guard let matchRange = code.range(
            of: "found.first(where: { $0.udid == udid })",
            range: scanRange.upperBound..<code.endIndex) else {
            return XCTFail("scan の結果から udid が一致するポートを選ぶ配線が無い")
        }
        XCTAssertTrue(scanRange.upperBound < matchRange.lowerBound)
        // 一致したポートへ乗り換えて resolve をやり直すこと(二つ目の実装を書かず
        // XCUIBridgeResolver.resolve を再利用する)
        guard let rerouteRange = code.range(
            of: "preferred: match.port", range: matchRange.upperBound..<code.endIndex) else {
            return XCTFail("一致したポート(match.port)へ resolve をやり直していない")
        }
        XCTAssertTrue(matchRange.upperBound < rerouteRange.lowerBound)
    }

    /// **見つからなければ別の台のブリッジには触れず、空きポートへ自動起動を回す**
    /// (占有中の既定ポートを巻き込まない。実地 L1: 版差を理由に他人のブリッジを止めていた)
    func testNoMatchFallsBackToAFreePortWithoutTouchingTheOccupiedOne() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let matchRange = code.range(of: "found.first(where: { $0.udid == udid })") else {
            return XCTFail("scan マッチの配線が見当たらない — テストを見直すこと")
        }
        guard let freePortRange = code.range(
            of: "XCUIBridgeResolver.freePort(", range: matchRange.upperBound..<code.endIndex) else {
            return XCTFail("一致するポートが無いとき、空きポートを選んでいない"
                + " — 占有中の既定ポートをそのまま自動起動が触りにいく(他人のブリッジを巻き込む)")
        }
        // 占有中の既定ポートと、scan で見つかった生きているポート全部を occupied から除外すること
        let freePortCall = String(code[freePortRange.lowerBound...].prefix(300))
        XCTAssertTrue(freePortCall.contains("driverOptions.resolvedPort"),
                      "occupied 集合に既定ポート自身も入れること")
        XCTAssertTrue(freePortCall.contains("found.map"),
                      "occupied 集合に scan で見つかった生きているポートも入れること")
    }

    /// hybrid の in-app 側(別ポート)も本人確認する——xcuitest 側だけでは検分できない
    func testHybridInAppEndpointIsAlsoVerified() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let composeRange = code.range(of: "private func composeDriver(") else {
            return XCTFail("composeDriver が見当たらない — テストを見直すこと")
        }
        guard let guardRange = code.range(
            of: "guard let inApp = resolution.inApp", range: composeRange.upperBound..<code.endIndex)
        else {
            return XCTFail("hybrid 判定の guard が見当たらない — テストを見直すこと")
        }
        guard let secondVerifyRange = code.range(
            of: "endpoint: inApp.endpoint", range: guardRange.upperBound..<code.endIndex) else {
            return XCTFail("hybrid の in-app 側(inApp.endpoint)を本人確認していない")
        }
        XCTAssertTrue(guardRange.upperBound < secondVerifyRange.lowerBound)
    }

    /// checkAndRestartIfStale は本人確認してから初めて「古い版」の判定・再起動へ進む
    /// (他人のブリッジを版差だけを理由に止めない)
    func testCheckAndRestartIfStaleVerifiesIdentityBeforeRestarting() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        guard let statusRange = code.range(of: "guard let status = try? await client.status()") else {
            return XCTFail("status の取得箇所が変わった — テストを見直すこと")
        }
        guard let identityRange = code.range(
            of: "BridgeIdentityCheck.matches(expected: expected, status: status)") else {
            return XCTFail("checkAndRestartIfStale が BridgeIdentityCheck で本人確認していない"
                + " — 別デバイスの生きたブリッジを版差を理由に止めて建て直す(実地 L1)")
        }
        guard let restartLogRange = code.range(of: "Detected a bridge from an older build") else {
            return XCTFail("再起動のログ文言が変わった — テストを見直すこと")
        }
        XCTAssertTrue(statusRange.upperBound < identityRange.lowerBound)
        XCTAssertTrue(identityRange.upperBound < restartLogRange.lowerBound,
                      "本人確認は「古い版」の判定・再起動より前に行うこと")
        // 一致しなければ return する(その先の再起動処理を1行も踏まない)
        XCTAssertTrue(code.contains("!BridgeIdentityCheck.matches(expected: expected, status: status)"),
                      "不一致を検知したら早期 return すること")
    }
}
