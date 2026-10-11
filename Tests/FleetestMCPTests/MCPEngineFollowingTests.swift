// **MCP の iOS は、実行プロファイルのエンジンに関わらず XCUITest で組む**ことを固定する(ユーザー決定)。
//
// 以前はプロファイルの in-app / hybrid に追従していたが、in-app の合成タッチは注入される前提で作られていない
// アプリ(Apple マップの経路カード等)で効かないまま ok を返し、別アプリ・システムアラートの扱いでもエンジンを
// 意識させた。ここが静かに in-app / hybrid へ戻ると、その形が再び起きる。
//
// **実ブリッジに触らない**: iosDriver / ExploreDriverResolver は XCUIBridgeResolver でブリッジを探し、無ければ
// 起動まで試みる(ユニットテストから手元のデバイスを動かしうる)。組み立てに in-app / hybrid を作る行が無いことを
// ソースで確かめ、判定は純粋関数で確かめる。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class MCPEngineFollowingTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// コメントを落としたコード行(doc コメントや経緯の説明に型名が出ても数えない)
    private func code(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop { $0 == " " }
                return trimmed.hasPrefix("//") ? "" : line
            }
            .joined(separator: "\n")
    }

    /// **MCP の iOS の組み立てに in-app / hybrid を作る行が無い**(profile 経路の iosDriver と、直接ポート経路の
    /// ExploreDriverResolver の両方)。変異: どちらかに InAppDriver / hybrid の合成を戻すと落ちる
    func testNoInAppOrHybridIsComposedForMCP() throws {
        for path in ["Sources/fleetest-mcp/MCPServer+Driver.swift", "Sources/FTBridgeClient/ExploreDriverResolver.swift"] {
            let source = try code(path)
            for forbidden in ["InAppDriver(", "HybridFallbackDriver(", "HybridDriverComposition."] {
                XCTAssertFalse(source.contains(forbidden), "\(path) が \(forbidden) で in-app / hybrid を組んでいる")
            }
        }
    }

    /// **profile 経路は XCUITest で供給する**(プロファイルが in-app / hybrid でも、使わない注入付きの起動を走らせない)
    func testProfileProvisioningForcesTheXCUITestEngine() throws {
        let source = try code("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        XCTAssertTrue(source.contains("spec.engine = \"xcuitest\""), "profile 経路が XCUITest で供給していない")
        XCTAssertTrue(source.contains("devices: [(device.name, spec)]"), "差し替えた spec を供給へ渡していない")
    }

    /// **profile の autoInstall は MCP でも効く**: 供給が先に入れるのは in-app のときだけなので、XCUITest で供給する
    /// MCP は自分で入れる(入っていないときだけ。入れ直しは動いているアプリを終了させる)。差し替えドライバでは
    /// profile 経路を通れないので、配線をソースで固定する
    func testProfilePathInstallsTheAppWhenAutoInstallIsSetAndItIsAbsent() throws {
        let source = try code("Sources/fleetest-mcp/MCPServer+Driver.swift")
        // enforceVersion は profile 経路(先)と直接ポート経路(後)の2箇所で呼ぶ。その間が profile 経路の末尾
        let parts = source.components(separatedBy: "try await enforceVersion(driver: created, key: key, args: args)")
        XCTAssertEqual(parts.count, 3, "enforceVersion の呼び出しが2箇所から変わった(目印を見直す)")
        let profileTail = parts.count >= 2 ? parts[1] : ""
        XCTAssertTrue(profileTail.contains("iosApp.autoInstall"), "profile 経路が autoInstall を見ていない")
        XCTAssertTrue(profileTail.contains("== .notInstalled"), "入っているアプリまで入れ直している(動いているアプリが終了する)")
        XCTAssertTrue(profileTail.contains("created.install(packagePath: packagePath)"), "profile 経路がアプリを入れていない")
    }

    /// **実機には probePort を出さない**。実機のブリッジは loopback ではないので、
    /// ポート番号だけで 127.0.0.1 を叩くと**無関係なシミュレータのブリッジを読む** ——
    /// `deviceIdentityChanged` が別の機の udid を見て、正しい呼び出しを拒否し記憶まで捨てる
    func testProbePortIsOnlyForLoopbackSimulators() {
        let loopback = BridgeEndpoint(port: 8137)
        XCTAssertEqual(MCPServer.probePort(physical: false, endpoint: loopback), 8137)
        XCTAssertNil(MCPServer.probePort(physical: true, endpoint: loopback), "実機に loopback の probe ポートを出した")
    }
}
