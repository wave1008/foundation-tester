// SSHOptions の定数はリテラルで固定し、ssh の基本オプションを組み立てる呼び手の配線はソース走査で固定する
// (Sources/fleetest 側は FTCore の外なので文字列でしか見られない。rsync 側は RemoteDispatchTests の配列一致)

import FTRemote
import Foundation
import XCTest

final class SSHOptionsTests: XCTestCase {

    // MARK: - 定数はリテラルで固定(production の定数を期待値に使わない)

    func testServerAliveIntervalIsFifteenSeconds() {
        XCTAssertEqual(SSHOptions.serverAliveIntervalSeconds, 15)
    }

    func testServerAliveCountMaxIsFour() {
        XCTAssertEqual(SSHOptions.serverAliveCountMax, 4)
    }

    func testKeepAliveArgsIsTheOPairsInOrder() {
        XCTAssertEqual(SSHOptions.keepAliveArgs, [
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
        ])
    }

    func testRsyncRemoteShellArgsWrapsSshAndTheSameOptionsAsOneShellWord() {
        XCTAssertEqual(SSHOptions.rsyncRemoteShellArgs, [
            "-e", "ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
        ])
    }

    // MARK: - 呼び手(ssh/scp の基本オプションを組み立てている箇所)が SSHOptions を通すこと
    // (grep で全部列挙した3箇所のうち Sources/fleetest 配下の2つ。FTRemote の rsync 側は
    // RemoteDispatchTests の rsyncArgs 各テストが厳密な配列一致で固定する)

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    func testRemoteRunDispatcherSshBaseFoldsInKeepAlive() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("+ SSHOptions.keepAliveArgs"),
                      "sshBase must fold in SSHOptions.keepAliveArgs — without it, a silently"
                      + " dead connection is only noticed via the OS's own TCP timeout"
                      + " (tens of minutes on macOS)")
    }

    func testRemoteSetupCommandBasesFoldInKeepAlive() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/fleetest/RemoteSetupCommand.swift"),
            encoding: .utf8)
        for base in ["setupSSHBase", "setupSCPBase"] {
            guard let range = source.range(of: "\(base) = ") else {
                XCTFail("\(base) definition not found"); continue
            }
            let line = source[range.lowerBound...]
                .prefix(while: { $0 != "\n" })
            XCTAssertTrue(line.contains("SSHOptions.keepAliveArgs"),
                          "\(base) must fold in SSHOptions.keepAliveArgs: \(line)")
        }
    }

    /// `remote status` / `remote clean` / unlock の ssh(remoteSSHBase)も同じ定義を通す
    func testRemoteCommandsSshBaseFoldsInKeepAlive() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/fleetest/RemoteCommands.swift"),
            encoding: .utf8)
        guard let range = source.range(of: "remoteSSHBase = ") else {
            return XCTFail("remoteSSHBase definition not found")
        }
        let line = source[range.lowerBound...].prefix(while: { $0 != "\n" })
        XCTAssertTrue(line.contains("SSHOptions.keepAliveArgs"),
                      "remoteSSHBase must fold in SSHOptions.keepAliveArgs: \(line)")
    }
}
