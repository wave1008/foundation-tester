import Foundation
import XCTest
@testable import FTCore
import FTRemote
@testable import fleetest

/// dispatch.lock で始まらなかった理由を、起こした側(MCP の ft_start_run)へ構造化して渡す(拒否の文言を一致で判定しない)
final class DispatchRefusalReportTests: XCTestCase {

    /// 待たずに断った / 待ったが期限切れ、を書き分け、置き場が渡されていなければ書かない
    func testRefusedWritesTheReasonOnlyWhenAsked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.json")
        let env = [DispatchRefusalReport.environmentKey: url.path]
        let busy = DispatchWaitStatus(target: "this Mac", position: 2, total: 2, holder: nil,
                                      elapsedSeconds: 0, limitSeconds: nil, scope: .thisMachine)
        XCTAssertEqual(busy.refused(environment: env), busy.refusalMessage)
        XCTAssertEqual(DispatchRefusalReport.read(url), .init(limitSeconds: nil, waitedSeconds: 0))
        let expired = DispatchWaitStatus(target: "this Mac", position: 1, total: 1, holder: nil,
                                         elapsedSeconds: 60, limitSeconds: 60, scope: .thisMachine)
        _ = expired.refused(environment: env)
        XCTAssertEqual(DispatchRefusalReport.read(url), .init(limitSeconds: 60, waitedSeconds: 60))
        try FileManager.default.removeItem(at: url)
        _ = busy.refused(environment: [:])
        XCTAssertNil(DispatchRefusalReport.read(url))
    }

    /// 拒否の throw は必ず `refused()` を通す(`refusalMessage` を直に投げると記録が書かれず、MCP は案内できない)
    func testEveryRefusalThrowGoesThroughRefused() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for (file, expected) in [("Sources/fleetest/LocalDispatchLock.swift", 2), ("Sources/fleetest/RemoteRunDispatcher.swift", 2)] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "status.refused()").count - 1, expected, file)
            XCTAssertFalse(text.contains("status.refusalMessage"), "\(file) throws the refusal without writing the record")
        }
        // 状態を作らずに断るリモートの経路(以前のディスパッチ元は居ないが向こうの run は生きている)も記録を書く(Codex 再レビュー)
        let remote = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"), encoding: .utf8)
        guard let kept = remote.range(of: "case .keptBecauseRunIsAlive(let reason):"),
              let write = remote.range(of: "DispatchRefusalReport.write(", range: kept.upperBound..<remote.endIndex),
              let thrown = remote.range(of: "throw RemoteDispatchError.remoteSetupFailed(", range: kept.upperBound..<remote.endIndex) else {
            return XCTFail("the kept-lock refusal no longer writes the record before throwing")
        }
        XCTAssertLessThan(write.lowerBound, thrown.lowerBound)
        // 機械分担の親は拒否を捕まえて残りの機械で続ける = 拒否で終わらないので記録を消す
        let prelock = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/DispatchPrelock.swift"), encoding: .utf8)
        XCTAssertNotNil(prelock.range(of: "} catch {\n                // 拒否の記録を取り消す"), "a caught (non-final) refusal leaves its record behind")
        XCTAssertNotNil(prelock.range(of: "DispatchRefusalReport.clear()"))
        // MCP は記録があれば時刻だけの照合をしない(同じ project / profile の別の run の結果を出す)
        let jobs = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/MCPServer+RunJobs.swift"), encoding: .utf8)
        XCTAssertNotNil(jobs.range(of: "} else if refusal == nil, let found = MCPRunJobs.matchRunMeta("))
    }

    /// `ParentDeathWatch.childEnvironment` を通らない常駐の子(services の所有者・FM の常駐・背景の掃除)へも置き場を渡さない
    func testResidentChildrenDoNotInheritTheReportPath() {
        let base = [DispatchRefusalReport.environmentKey: "/x.json", "KEEP": "1"]
        let roots = RetentionSweeper.Roots(package: URL(fileURLWithPath: "/p"), tool: URL(fileURLWithPath: "/t"))
        for (name, env) in [("services owner", ServicesOwnerLaunch.environment(base: base)),
                            ("fm-serve", FMServeHost.serverEnvironment(base)),
                            ("retention sweep", RunCompletionSweep.childEnvironment(roots: roots, base: base))] {
            XCTAssertNil(env[DispatchRefusalReport.environmentKey], name)
            XCTAssertEqual(env["KEEP"], "1", name)
        }
    }

    /// fleetest が起こす子(機械ごとの sub-run)へは置き場を渡さない(子の拒否は子の終わり方で、起こされたプロセスの終わり方ではない)
    func testChildrenDoNotInheritTheReportPath() {
        let env = ParentDeathWatch.childEnvironment(base: [DispatchRefusalReport.environmentKey: "/x.json", "KEEP": "1"])
        XCTAssertNil(env[DispatchRefusalReport.environmentKey])
        XCTAssertEqual(env["KEEP"], "1")
    }
}
