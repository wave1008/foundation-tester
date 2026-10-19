// Android の run 前の点検(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers`)の結果を run.json へ載せる呼び手は、
// `triage.anomalies` を使う(除外の理由を台ごとに持つ = ネットワークの無い Emulator を「画面が凍結」と書かない)。
// `WorkerAnomalyRecord.preRunTriage(excluded: triage.excludedWorkers, …)` と自分で組むと理由が落ちる

import XCTest

final class PreRunTriageRecordWiringTests: XCTestCase {

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"), encoding: .utf8)
    }

    func testAndroidTriageCallersUseTheRecordsThatCarryTheReasons() throws {
        for name in ["ApiRunCommand.swift", "ProfileRunner.swift"] {
            let code = try Self.source(name)
            XCTAssertFalse(code.contains("excluded: triage.excludedWorkers"),
                           "\(name): Android の点検の記録は triage.anomalies から作る(除外の理由が落ちる)")
            XCTAssertTrue(code.contains("triage.anomalies"), "\(name): 走査が呼び手に届いていない")
        }
    }
}
