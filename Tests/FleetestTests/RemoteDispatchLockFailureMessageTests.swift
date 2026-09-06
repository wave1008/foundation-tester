// RemoteRunDispatcher の ssh 規律2つ:
//   1. **全部の ssh は sshBase(BatchMode / ConnectTimeout)を通す**。素の `"ssh"` で起動すると
//      鍵の無いホストでパスワード入力に止まり、到達不能ホストで TCP 既定(75 秒超)固まる
//      (transferWebViewCache の mkdir がこれだった)
//   2. dispatch.lock の取得失敗は「控えが空 = 誰も掴んでいない」と「掴まれている」を分ける。
//      前者を held と言うと、権限や base の誤りで永久に "holder unknown" を見せ続ける

import XCTest
import FTRemote
@testable import fleetest

final class RemoteDispatchLockFailureMessageTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// `"ssh"` リテラルを書いてよいのは sshBase の定義行だけ
    func testNoSshIsSpawnedOutsideSshBase() throws {
        let lines = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"),
            encoding: .utf8).components(separatedBy: "\n")
        let offenders = lines.enumerated().filter { _, line in
            line.contains("\"ssh\"") && !line.contains("BatchMode=yes")
        }.map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        XCTAssertEqual(offenders, [], "sshBase を通さない ssh(BatchMode/ConnectTimeout 無し)")
        XCTAssertTrue(lines.contains { $0.contains("\"ssh\", \"-o\", \"BatchMode=yes\", \"-o\", \"ConnectTimeout=10\"") },
                      "sshBase の定義が見つからない(書式を見直す)")
    }

    // MARK: - dispatchLockFailureMessage

    private var heldInfo: String {
        RemoteDispatchLock.encode(RemoteDispatchLockInfo(
            issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2026-09-07T00:00:00Z", issuer: "wave1008"))!
    }

    /// 控えが読めて中身がある = 掴まれている
    func testHeldLockNamesTheHolder() {
        let message = RemoteRunDispatcher.dispatchLockFailureMessage(
            status: 1, lockRead: heldInfo, tail: "", sshTarget: "user@runner")
        XCTAssertTrue(message.contains("another dispatch is already running"), message)
        XCTAssertTrue(message.contains("wave1008"), message)
        XCTAssertFalse(message.contains("could not create"), message)
    }

    /// 控えが**空**(readCommand は不在でも exit 0 で空)= 誰も掴んでいない → mkdir の失敗そのもの
    func testEmptyLockReadReportsTheActualError() {
        let message = RemoteRunDispatcher.dispatchLockFailureMessage(
            status: 1, lockRead: "", tail: "mkdir: /Volumes/x/.fleetest: Permission denied",
            sshTarget: "user@runner")
        XCTAssertTrue(message.hasPrefix("could not create the dispatch lock on user@runner (ssh status 1)"), message)
        XCTAssertTrue(message.contains("Permission denied"), message)
        XCTAssertFalse(message.contains("another dispatch"), message)
    }

    /// 空の控え + stderr も空(mkdir は 2>/dev/null)= 直前に解放された可能性 → retry を案内
    func testEmptyLockReadWithoutStderrSuggestsRetry() {
        let message = RemoteRunDispatcher.dispatchLockFailureMessage(
            status: 1, lockRead: "", tail: "", sshTarget: "user@runner")
        XCTAssertTrue(message.contains("no error output"), message)
        XCTAssertTrue(message.contains("retry"), message)
    }

    /// 控えが読めない(nil)・壊れている = holder unknown の held 文言(従来どおり)
    func testUnreadableOrCorruptLockFallsBackToHolderUnknown() {
        for read in [nil, "{not json"] {
            let message = RemoteRunDispatcher.dispatchLockFailureMessage(
                status: 1, lockRead: read, tail: "x", sshTarget: "user@runner")
            XCTAssertTrue(message.contains("holder unknown"), message)
            XCTAssertFalse(message.contains("could not create"), message)
        }
    }
}
