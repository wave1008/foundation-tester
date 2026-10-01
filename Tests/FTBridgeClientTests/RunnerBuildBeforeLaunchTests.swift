import Foundation
import XCTest

/// XCUITest ランナーの起動の段は、準備段(`prepareSharedBuilds`)の保証に頼らず
/// `ensureRunnerBuilt` を通してから `startDetached` すること。計画の後で `.reuse`(ツールチェーン不一致・
/// 劣化)や `.adopt` から `.launch` へ切り替わる経路は準備段を通らず、xctestrun が無いと
/// `xctestrunNotFound` で落ちていた(別クローンのランナーが居るデバイスで、新しいクローンの最初の
/// ft_* が失敗した)。素通りしてもコンパイルは通るので、ソース走査で固定する。
final class RunnerBuildBeforeLaunchTests: XCTestCase {

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

    private static func lines(_ code: String) -> [String] {
        code.components(separatedBy: "\n")
    }

    /// 起動口は2つ(通常の起動と、portInUse の後の1回だけの再試行)。増えたら、その口が
    /// ensureRunnerBuilt を通るかを見直してからこの数を上げる
    func testStartDetachedCallSitesArePinned() throws {
        let sites = Self.lines(try Self.source).filter { $0.contains("launcher.startDetached()") }
        XCTAssertEqual(sites.count, 2, "BridgeProvisioner の startDetached の呼び出しが増減した: \(sites)")
    }

    /// 最初の起動口(通常の起動)は、同じ detached ブロックの中で ensureRunnerBuilt を先に通すこと
    func testFirstLaunchEnsuresRunnerBuiltBeforeStarting() throws {
        let lines = Self.lines(try Self.source)
        let launch = try XCTUnwrap(lines.firstIndex { $0.contains("launcher.startDetached()") })
        let window = lines[max(0, launch - 4)..<launch].joined(separator: "\n")
        XCTAssertTrue(window.contains("Self.ensureRunnerBuilt("),
                      "起動の段が ensureRunnerBuilt を通さずに startDetached している:\n\(window)")
    }

    /// 準備段も同じ判定を使うこと(片方だけ判定を持つと、ビルドの要否が経路で食い違う)
    func testPrepareSharedBuildsUsesTheSameCheck() throws {
        let code = try Self.source
        let start = try XCTUnwrap(code.range(of: "private func prepareSharedBuilds("))
        let end = try XCTUnwrap(code.range(of: "static func ensureRunnerBuilt(",
                                           range: start.upperBound..<code.endIndex))
        let body = String(code[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.ensureRunnerBuilt("), "prepareSharedBuilds が ensureRunnerBuilt を使っていない")
        XCTAssertFalse(body.contains("launcher.buildForTesting()"),
                       "prepareSharedBuilds が判定を介さず build-for-testing を直接撃っている")
    }
}
