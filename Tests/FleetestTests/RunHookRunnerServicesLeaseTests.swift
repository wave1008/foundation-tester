import Foundation
import XCTest
@testable import fleetest

/// 終了スクリプトの孤児回収(`RunHookRunner.reapOrphans`)は、同じ置き場にあるサービスの控え(`<pid>~<prefix>.json`)を
/// 「読めない記録」として消してはいけない(消すと、生きている run のサービスが回収不能になる。回収は `ServicesReaper` の役目)
final class RunHookRunnerServicesLeaseTests: XCTestCase {
    func testReapOrphansLeavesServicesLeasesAlone() throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-hooks-reap-\(UUID().uuidString)")
        let hooks = stateDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // サービスの控え(中身は RunHookLeaseInfo として decode できない形)と、旧形式の壊れた控え
        let services = hooks.appendingPathComponent("4242~fleetest-0123456789ab.json")
        let broken = hooks.appendingPathComponent("4243.json")
        try Data("{\"schemaVersion\":1,\"pid\":4242}".utf8).write(to: services)
        try Data("not json".utf8).write(to: broken)

        _ = RunHookRunner.reapOrphans(stateDir: stateDir) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: services.path),
                      "a services lease must survive the teardown-script reaper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path),
                       "an unreadable old-style lease is still removed")
    }
}
