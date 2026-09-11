// the restart log for an unresponsive adopted bridge used to say "the starting bridge …
// has been alive for Ns without answering … so the process that launched it has already given
// up" — but `launcher.runnerElapsed()` (BridgeProvisioner.swift) is the runner *process's* total
// lifetime (`ps -o etime=`), not the time since it stopped answering. A bridge that had been
// answering fine for a long time and only froze recently (e.g. a backgrounded XCUITest runner
// killed by a coordinate gesture) hits the exact same restart path and got the same "still
// starting, never answered" narrative, which is false for that case. The fix drops the "starting"
// framing and the "already given up" causal claim from the message; this is a literal-text
// regression test since the message is a string built inline in BridgeProvisioner.swift (no
// separate pure function to unit test — see StartingRunnerVerdictTests.swift for the decision
// logic itself, which is unchanged).

import Foundation
import XCTest

final class StaleBridgeRestartMessageTests: XCTestCase {

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTBridgeClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRestartLogDoesNotClaimTheBridgeIsStillStarting() throws {
        let code = try Self.source()
        XCTAssertFalse(code.contains("the starting bridge on port"),
                       "戻すと、長く応答していたが最近固まっただけのブリッジにも「起動中」と断定する")
        XCTAssertFalse(code.contains("the process that launched it has"),
                       "戻すと、無応答になった経緯を知らないのに「起動した側は諦めた」と断定する")
    }

    func testRestartLogStillNamesTheBudgetAndAction() throws {
        let code = try Self.source()
        XCTAssertTrue(code.contains("without answering (past the"),
                      "無応答であること・予算超過であることは事実として残す")
        XCTAssertTrue(code.contains("stopping and restarting it"))
    }
}
