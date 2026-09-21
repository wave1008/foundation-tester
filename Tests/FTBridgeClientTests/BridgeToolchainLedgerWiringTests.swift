import Foundation
import XCTest

/// `BridgeProvisioner` の `.reuse`/`.adopt` は返す前に必ず `BridgeToolchainLedger.matchesCurrent` を
/// 通ること・`.launch` の ready 合流点(両エンジン共通)は必ず `record` すること。比較を素通りしても
/// コンパイルは通る(型で守れない境界)ので、ソース走査で固定する
/// (docs/verification.md 「型の効かない境界の改名は往復テストで縛る」と同じ規律)。
final class BridgeToolchainLedgerWiringTests: XCTestCase {

    private static var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // FTBridgeClientTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリルート
                .appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// `.reuse` は返す前にツールチェーンの一致を確かめること(素通りすると旧 Xcode のまま使い続ける ——
    /// これが今回直す実害)
    func testReuseChecksToolchainBeforeReturning() throws {
        let code = try Self.source
        XCTAssertTrue(
            code.contains("BridgeToolchainLedger.matchesCurrent(stateDir: fleetestStateDir, port: port)"),
            ".reuse 経路が BridgeToolchainLedger.matchesCurrent を通っていない")
    }

    /// `.adopt`(別プロセスが起こした直後の引き取り)も同じ判定を通すこと ——
    /// 同じ機械でも発行者ごとに Xcode が違いうる
    func testAdoptAlsoChecksToolchain() throws {
        let code = try Self.source
        // **引数まで固定しない**(改行が入っただけで落ちる)。見るのは呼び出しの本数だけ
        let occurrences = code.components(separatedBy: "BridgeToolchainLedger.matchesCurrent(").count - 1
        XCTAssertEqual(occurrences, 2, ".reuse と .adopt の両方が matchesCurrent を通ること(片方だけだと"
            + " 同じ機械の別発行者が建てたブリッジを他方の経路で取りこぼす)")
    }

    /// `.reuse` の仕分けは純粋関数を通すこと。**ソースの順序で縛らない** —— 順序は
    /// リファクタで動くが、リースのある台に触らない規律は `decide` が持つ
    func testReuseRoutesTheDecisionThroughThePureFunction() throws {
        let code = try Self.source
        XCTAssertTrue(code.contains("BridgeToolchainLedger.decide("),
                      ".reuse がツールチェーンの仕分けを自前の分岐で持っている")
        XCTAssertTrue(code.contains("hasForeignLease: RunnerAccessibilityHealth.hasForeignLease("),
                      "リースの有無を decide へ渡していない(リースのある台を殺しうる)")
    }

    /// **`.restart` が実際に止めて建て直すこと**。`decide` を呼ぶだけでは、その枝が空でも
    /// 緑のまま通る(実際に変異で素通りした)。止める指定(`stopStalePort`)まで見る
    func testRestartBranchActuallyStopsAndRelaunchesTheBridge() throws {
        let code = try Self.source
        guard let restart = code.range(of: "case .restart:") else {
            return XCTFail("`.reuse` の仕分けに .restart の枝が無い")
        }
        // 枝の中身 = 次の `case ` か switch の閉じまで。相対位置ではなく**この枝の中**を見る
        let rest = code[restart.upperBound...]
        let branch = rest.range(of: "\n            case ").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest.prefix(1200))
        XCTAssertTrue(branch.contains("stopStalePort: port"),
                      ".restart が古いブリッジを止めていない(止めずに建て直すとポートが衝突する)")
        XCTAssertTrue(branch.contains("executeBridge("),
                      ".restart が建て直していない(版の違うブリッジをそのまま使い続ける)")
    }

    /// **`record` は起動(waitUntilReady)より前**。ready の後に書くと、別プロセスが `.adopt` で
    /// このブリッジを引き取るときに「控え無し」を見て、**正常なブリッジを止めてしまう** ——
    /// 引き取る側は /status が答えた瞬間に見に来るので、必ずその窓に入りうる
    func testRecordHappensBeforeTheBridgeBecomesReachable() throws {
        let code = try Self.source
        guard let recordRange = code.range(of: "BridgeToolchainLedger.record(stateDir: stateDir, port: port)")
        else {
            return XCTFail("`.launch` が record していない(reuse/adopt の比較相手が永久に無い)")
        }
        // `.launch` の中の待ち(引き取る側から見える瞬間)より前にあること
        let afterRecord = code[recordRange.upperBound...]
        XCTAssertTrue(afterRecord.contains("waitUntilReady"),
                      "record が `.launch` の待ちより後にある(引き取り側が空の控えを見る)")
        XCTAssertEqual(code.components(separatedBy: "BridgeToolchainLedger.record(").count - 1, 1,
                       "record は1箇所だけ(両エンジンの合流点)")
    }

}
