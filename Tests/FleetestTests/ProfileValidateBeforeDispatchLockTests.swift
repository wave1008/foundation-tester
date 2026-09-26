// The read-only validation of --profile / --device / --device-machine (ProfileResolver.resolve +
// filteringDevices) must run before this Mac's dispatch.lock in both commands
// (`ApiRunCommand.resolveProfileDevicesBeforeLock` / `RunScenarios.validateProfileDevicesBeforeLock`),
// so a typo is reported without waiting behind another run; the writes (WorkspaceScaffold.ensure /
// WorkspaceAppStaging / hooks / supply) stay after it.
//
// Same technique as DispatchLockBeforeBuildOrderingTests.swift: this ordering can't be driven by
// a normal unit test without a real dispatch.lock held by another process, so pin the source
// shape — within each `run()` body, the pre-lock validation call must appear before
// `LocalDispatchLock(`.

import Foundation
import XCTest
@testable import fleetest

final class ProfileValidateBeforeDispatchLockTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// `run()` の本体だけを見る(切り出した検証ヘルパー自身の**定義**は `run()` より前にあるので、
    /// ファイル全体を素の文字列検索すると定義行がヒットして「常に前にある」ことになり、
    /// 呼び出し位置を確かめたことにならない)
    private static func runBody(_ text: String, marker: String = "func run() async throws {") throws -> Substring {
        guard let start = text.range(of: marker)?.lowerBound else {
            throw XCTSkip("marker not found")
        }
        return text[start...]
    }

    func testApiRunCommandValidatesProfileDevicesBeforeAcquiringTheLock() throws {
        let text = try Self.source("Sources/fleetest/ApiRunCommand.swift")
        let body = try Self.runBody(text)
        guard let validateRange = body.range(of: "try resolveProfileDevicesBeforeLock(") else {
            return XCTFail("resolveProfileDevicesBeforeLock is not called from run()")
        }
        guard let lockRange = body.range(of: "LocalDispatchLock(") else {
            return XCTFail("LocalDispatchLock( not found in run()")
        }
        XCTAssertLessThan(validateRange.lowerBound, lockRange.lowerBound,
                          "the profile/device validation must run before the dispatch lock is acquired")
    }

    func testRunScenariosValidatesProfileDevicesBeforeAcquiringTheLock() throws {
        let text = try Self.source("Sources/fleetest/Fleetest.swift")
        let body = try Self.runBody(text)
        guard let validateRange = body.range(of: "try validateProfileDevicesBeforeLock()") else {
            return XCTFail("validateProfileDevicesBeforeLock() is not called from run()")
        }
        guard let lockRange = body.range(of: "LocalDispatchLock(") else {
            return XCTFail("LocalDispatchLock( not found in run()")
        }
        XCTAssertLessThan(validateRange.lowerBound, lockRange.lowerBound,
                          "the profile/device validation must run before the dispatch lock is acquired")
    }

    /// 書き込み(ワークスペースの雛形・供給)はロックの後のまま —— 前へ出したのは読むだけの
    /// 判定だけであること。ApiRunCommand は自分の run() の中で直接 WorkspaceScaffold.ensure を
    /// 呼ぶが、RunScenarios はそれを ProfileRunner.run(…) の内側(別ファイル)へ委ねているので、
    /// その呼び出し自体がロックの後にあることを見る
    func testWorkspaceWritesStayAfterTheLockInApiRunCommand() throws {
        let text = try Self.source("Sources/fleetest/ApiRunCommand.swift")
        let body = try Self.runBody(text)
        guard let lockRange = body.range(of: "LocalDispatchLock(") else {
            return XCTFail("LocalDispatchLock( not found in run()")
        }
        guard let scaffoldRange = body.range(of: "WorkspaceScaffold.ensure(") else {
            return XCTFail("WorkspaceScaffold.ensure( not found in run()")
        }
        XCTAssertLessThan(lockRange.lowerBound, scaffoldRange.lowerBound,
                          "workspace scaffolding must stay after the dispatch lock"
                          + " (only the read-only validation moved earlier)")
    }

    func testProfileRunnerCallStaysAfterTheLockInRunScenarios() throws {
        let text = try Self.source("Sources/fleetest/Fleetest.swift")
        let body = try Self.runBody(text)
        guard let lockRange = body.range(of: "LocalDispatchLock(") else {
            return XCTFail("LocalDispatchLock( not found in run()")
        }
        // ProfileRunner.run(...) が WorkspaceScaffold.ensure/WorkspaceAppStaging を内包する
        // (writes)ので、その呼び出し自体がロックの後にあることを確かめる
        guard let profileRunnerCallRange = body.range(of: "try await ProfileRunner.run(") else {
            return XCTFail("ProfileRunner.run( is not called from run()")
        }
        XCTAssertLessThan(lockRange.lowerBound, profileRunnerCallRange.lowerBound,
                          "ProfileRunner.run (which writes the workspace scaffold) must stay after"
                          + " the dispatch lock (only the read-only validation moved earlier)")
    }

    /// dry-run はロックを取らない経路なので、`fleetest run`(`RunScenarios`)は
    /// dry-run のときこの前倒し検証を呼ばない(dry-run は元々 --device/--device-machine を
    /// 見ずに走る。前倒し検証を dry-run にも掛けると「--dry-run --device <typo>」が新たに
    /// 落ちるようになり、この修正と無関係な挙動が変わってしまう)
    func testRunScenariosSkipsTheEarlyValidationOnDryRun() throws {
        let text = try Self.source("Sources/fleetest/Fleetest.swift")
        let body = try Self.runBody(text)
        guard let validateRange = body.range(of: "try validateProfileDevicesBeforeLock()") else {
            return XCTFail("validateProfileDevicesBeforeLock() is not called from run()")
        }
        // 直前の行が `if !dryRun {` で始まっていること(同じ行に収まっている呼び出し規約)
        let before = body[body.startIndex..<validateRange.lowerBound]
        guard let lastLine = before.split(separator: "\n").last else {
            return XCTFail("could not find the line preceding the call")
        }
        XCTAssertTrue(lastLine.trimmingCharacters(in: .whitespaces).hasPrefix("if !dryRun {"),
                      "the call must be guarded by `if !dryRun`: \(lastLine)")
    }
}
