import Darwin
import FTCore
import Foundation
import XCTest
@testable import fleetest

/// スクリプトが終わったあとにプロセスグループへ残した子孫(`sleep … &`)を止めること、終了をパイプの EOF と独立に
/// 待つこと(孫が書込端を握っていても戻る)、控えに動いている子を書き・終わったら消すことを実プロセスで固定する。
final class RunHookRunnerProcessGroupTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-hook-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func script(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("setup.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `pgrep -f` で見つかる本数(自分の pgrep は -f の引数に当たらないように括弧で切る)
    private func running(_ marker: String) -> Int {
        let result = try? Shell.run(["/usr/bin/pgrep", "-f", marker], timeout: 5)
        return result?.output.split(separator: "\n").filter { !$0.isEmpty }.count ?? 0
    }

    /// 背景に残した `sleep` がパイプを握っていても、スクリプトの終了で戻り(EOF を待ち切らない)、孫は止められている
    func testLeftoverDescendantsAreStoppedAndTheRunnerDoesNotWaitForTheirEOF() throws {
        let marker = "ft-hook-orphan-\(UUID().uuidString.prefix(8))"
        // sleep は引数に印を持てないので、sh の `-c` の本文に印を埋めて pgrep -f で引く
        let url = try script("sh -c 'exec sleep 30 # \(marker)' &\necho started")
        var lines: [String] = []
        let started = Date()
        let status = RunHookRunner.execute(
            script: url, kind: .setup, workingDirectory: dir, environment: ["PATH": "/usr/bin:/bin"],
            stallThreshold: 60) { lines.append($0) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(status, 0, lines.description)
        XCTAssertLessThan(elapsed, 10, "the runner waited for the grandchild's pipe EOF (\(elapsed)s)")
        XCTAssertEqual(running(marker), 0, "the background sleep survived the process-group sweep")
        XCTAssertTrue(lines.contains { $0.contains("left processes running in its process group") }, lines.description)
    }

    /// 子孫を残さないスクリプトでは掃除の警告を出さない
    func testACleanScriptGetsNoSweepWarning() throws {
        let url = try script("echo ok")
        var lines: [String] = []
        let status = RunHookRunner.execute(
            script: url, kind: .teardown, workingDirectory: dir, environment: ["PATH": "/usr/bin:/bin"]) { lines.append($0) }
        XCTAssertEqual(status, 0)
        XCTAssertFalse(lines.contains { $0.contains("process group") }, lines.description)
    }

    /// 環境は渡したものだけ(親の環境を継がない)
    func testTheScriptSeesOnlyTheGivenEnvironment() throws {
        setenv("FT_HOOK_TEST_LEAK", "secret", 1)
        defer { unsetenv("FT_HOOK_TEST_LEAK") }
        let url = try script("echo \"leak=${FT_HOOK_TEST_LEAK:-none} given=$FT_GIVEN\"")
        var lines: [String] = []
        _ = RunHookRunner.execute(
            script: url, kind: .setup, workingDirectory: dir,
            environment: ["PATH": "/usr/bin:/bin", "FT_GIVEN": "yes"]) { lines.append($0) }
        XCTAssertTrue(lines.contains { $0.contains("leak=none given=yes") }, lines.description)
    }
}
